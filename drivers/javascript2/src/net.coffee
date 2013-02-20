goog.provide("rethinkdb.net")

goog.require("rethinkdb.base")
goog.require("rethinkdb.cursor")
goog.require("VersionDummy")
goog.require("Query2")
goog.require("goog.proto2.WireFormatSerializer")

class Connection
    DEFAULT_HOST: 'localhost'
    DEFAULT_PORT: 28016

    constructor: (host, callback) ->
        if typeof host is 'undefined'
            host = {}
        else if typeof host is 'string'
            host = {host: host}

        @host = host.host || @DEFAULT_HOST
        @port = host.port || @DEFAULT_PORT

        @outstandingCallbacks = {}
        @nextToken = 1
        @open = false

        @buffer = new ArrayBuffer 0

        @_connect = =>
            @open = true
            @_error = => # Clear failed to connect callback
            callback null, @

        @_error = => callback new RqlDriverError "Could not connect to server"

    _data: (buf) ->
        # Buffer data, execute return results if need be
        @buffer = bufferConcat @buffer, buf

        while @buffer.byteLength >= 4
            responseLength = (new DataView @buffer).getUint32 0, true
            responseLength2= (new DataView @buffer).getUint32 0, true
            unless @buffer.byteLength >= (4 + responseLength)
                break

            responseArray = new Uint8Array @buffer, 4, responseLength
            deserializer = new goog.proto2.WireFormatSerializer
            response = deserializer.deserialize Response2.getDescriptor(), responseArray
            @_processResponse response

            # For some reason, Arraybuffer.slice is not in my version of node
            @buffer = bufferSlice @buffer, (4 + responseLength)

    _end: -> @close()

    mkAtom = (response) -> DatumTerm.deconstruct response.getResponse 0

    mkSeq = (response) -> (DatumTerm.deconstruct res for res in response.responseArray())

    mkErr = (ErrClass, response, root) ->
        msg = mkAtom response
        bt = for frame in response.backtraceArray()
                if frame.getType() is Response2.Frame.FrameType.POS
                    parseInt frame.getPos()
                else
                    frame.getOpt()
        new ErrClass msg, root, bt

    _delQuery: (token) ->
        # This query is done, delete this cursor
        delete @outstandingCallbacks[token]

        if (k for own k of @outstandingCallbacks).length < 1 and not @open
            @cancel()

    _processResponse: (response) ->
        token = response.getToken()
        {cb:cb, root:root} = @outstandingCallbacks[token]
        if cb
            # Behavior varies considerably based on response type
            if response.getType() is Response2.ResponseType.COMPILE_ERROR
                cb mkErr(RqlCompileError, response, root)
                @_delQuery(token)
            else if response.getType() is Response2.ResponseType.CLIENT_ERROR
                cb mkErr(RqlClientErr, response, root)
                @_delQuery(token)
            else if response.getType() is Response2.ResponseType.RUNTIME_ERROR
                cb mkErr(RqlRuntimeError, response, root)
                @_delQuery(token)
            else if response.getType() is Response2.ResponseType.SUCCESS_ATOM
                cb null, mkAtom(response)
                @_delQuery(token)
            else if response.getType() is Response2.ResponseType.SUCCESS_PARTIAL
                cursor = new Cursor @, token
                cb null, cursor._addData(mkSeq response)
            else if response.getType() is Response2.ResponseType.SUCCESS_SEQUENCE
                cursor = new Cursor @, token
                cb null, cursor._endData(mkSeq response)
                @_delQuery(token)
            else
                cb new RqlDriverError "Unknown response type"
        else
            @_error new RqlDriverError "Unknown token in response"

    close: ->
        @open = false

    cancel: ->
        @outstandingCallbacks = {}
        @close()

    _start: (term, cb) ->
        unless @open then throw RqlDriverError "Connection closed"

        # Assign token
        token = ''+@nextToken
        @nextToken++

        # Construct query
        query = new Query2
        query.setType Query2.QueryType.START
        query.setQuery term.build()
        query.setToken token

        # Save callback
        @outstandingCallbacks[token] = {cb:cb, root:term}

        @_sendQuery(query)
        
    _continueQuery: (token) ->
        query = new Query2
        query.setType Query2.QueryType.CONTINUE
        query.setToken token

        @_sendQuery(query)

    _endQuery: (token) ->
        query = new Query2
        query.setType Query2.QueryType.STOP
        query.setToken token

        @_sendQuery(query)

    _sendQuery: (query) ->

        # Serialize protobuf
        serializer = new goog.proto2.WireFormatSerializer
        data = serializer.serialize query

        length = data.byteLength
        finalArray = new Uint8Array length + 4
        (new DataView(finalArray.buffer)).setInt32(0, length, true)
        finalArray.set data, 4

        @write finalArray.buffer

class TcpConnection extends Connection
    @isAvailable: -> typeof require isnt 'undefined' and require('net')

    constructor: (host, callback) ->
        unless TcpConnection.isAvailable()
            throw new RqlDriverError "TCP sockets are not available in this environment"

        super(host, callback)

        net = require('net')
        @rawSocket = net.connect @port, @host
        @rawSocket.setNoDelay()

        @rawSocket.on 'connect', =>
            # Initialize connection with magic number to validate version
            buf = new ArrayBuffer 4
            (new DataView buf).setUint32 0, VersionDummy.Version.V0_1, true
            @write buf
            @_connect()

        @rawSocket.on 'error', => @_error()

        @rawSocket.on 'end', => @_end()

        @rawSocket.on 'data', (buf) =>
            # Convert from node buffer to array buffer
            arr = new Uint8Array new ArrayBuffer buf.length
            for byte,i in buf
                arr[i] = byte
            @_data(arr.buffer)

    close: ->
        @rawSocket.end()
        super()

    cancel: ->
        @rawSocket.destroy()
        super()

    write: (chunk) ->
        # Alas we must convert to a node buffer
        buf = new Buffer chunk.byteLength
        for byte,i in (new Uint8Array chunk)
            buf[i] = byte

        @rawSocket.write buf

class HttpConnection extends Connection
    @isAvailable: -> typeof XMLHttpRequest isnt "undefined"
    constructor: (host, callback) ->
        unless HttpConnection.isAvailable()
            throw new RqlDriverError "XMLHttpRequest is not available in this environment"

        super(host, callback)

        url = "http://#{@host}:#{@port}/ajax/reql/"
        xhr = new XMLHttpRequest
        xhr.open("GET", url+"open-new-connection", true)
        xhr.responseType = "arraybuffer"

        xhr.onreadystatechange = (e) =>
            if xhr.readyState is 4
                if xhr.status is 200
                    @_url = url
                    @_connId = (new DataView xhr.response).getInt32(0, true)
                    @_connect()
                else
                    @_error()
        xhr.send()

    cancel: ->
        xhr = new XMLHttpRequest
        xhr.open("POST", "#{@_url}close-connection?conn_id=#{@_connId}", true)
        xhr.send()
        @_url = null
        @_connId = null
        super()

    write: (chunk) ->
        xhr = new XMLHttpRequest
        xhr.open("POST", "#{@_url}?conn_id=#{@_connId}", true)
        xhr.responseType = "arraybuffer"

        xhr.onreadystatechange = (e) =>
            if xhr.readyState is 4 and xhr.status is 200
                @_data(xhr.response)
        xhr.send chunk

class EmbeddedConnection extends Connection
    @isAvailable: -> (typeof RDBPbServer isnt "undefined")
    constructor: (embeddedServer, callback) ->
        super({}, callback)
        @_embeddedServer = embeddedServer
        @_connect()

    cancel: -> super()

    write: (chunk) -> @_data(@_embeddedServer.execute(chunk))

rethinkdb.connect = (host, callback) ->
    unless callback? then callback = (->)
    if TcpConnection.isAvailable()
        new TcpConnection host, callback
    else if HttpConnection.isAvailable()
        new HttpConnection host, callback
    else
        throw new RqlDriverError "Neither TCP nor HTTP avaiable in this environment"
    return

rethinkdb.embeddedConnect = (callback) ->
    unless callback? then callback = (->)
    unless EmbeddedConnection.isAvailable()
        throw new RqlDriverError "Embedded connection not available in this environment"
    new EmbeddedConnection new RDBPbServer, callback

bufferConcat = (buf1, buf2) ->
    view = new Uint8Array (buf1.byteLength + buf2.byteLength)
    view.set new Uint8Array(buf1), 0
    view.set new Uint8Array(buf2), buf1.byteLength
    view.buffer

bufferSlice = (buffer, offset) ->
    if offset > buffer.byteLength then offset = buffer.byteLength
    residual = buffer.byteLength - offset
    res = new Uint8Array residual
    res.set (new Uint8Array buffer, offset)
    res.buffer
