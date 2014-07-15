#     NoFlo - Flow-Based Programming for JavaScript
#     (c) 2014 TheGrid (Rituwall Inc.)
#     NoFlo may be freely distributed under the MIT license
StreamSender = require('./Streams').StreamSender
StreamReceiver = require('./Streams').StreamReceiver
InternalSocket = require './InternalSocket'

# MapComponent maps a single inport to a single outport, forwarding all
# groups from in to out and calling `func` on each incoming packet
exports.MapComponent = (component, func, config) ->
  config = {} unless config
  config.inPort = 'in' unless config.inPort
  config.outPort = 'out' unless config.outPort

  inPort = component.inPorts[config.inPort]
  outPort = component.outPorts[config.outPort]
  groups = []
  inPort.process = (event, payload) ->
    switch event
      when 'connect' then outPort.connect()
      when 'begingroup'
        groups.push payload
        outPort.beginGroup payload
      when 'data'
        func payload, groups, outPort
      when 'endgroup'
        groups.pop()
        outPort.endGroup()
      when 'disconnect'
        groups = []
        outPort.disconnect()

# WirePattern makes your component collect data from several inports
# and activates a handler `proc` only when a tuple from all of these
# ports is complete. The signature of handler function is:
# ```
# proc = (combinedInputData, inputGroups, outputPorts, asyncCallback) ->
# ```
#
# With `config.group = true` it checks incoming group IPs and collates
# data with matching group IPs. By default this kind of grouping is `false`.
# Set `config.group` to a RegExp object to correlate inputs only if the
# group matches the expression (e.g. `^req_`). For non-matching groups
# the component will act normally.
#
# With `config.field = 'fieldName' it collates incoming data by specified
# field. The component's proc function is passed a combined object with
# port names used as keys. This kind of grouping is disabled by default.
#
# With `config.forwardGroups = true` it would forward group IPs from
# inputs to the output sending them along with the data. This option also
# accepts string or array values, if you want to forward groups from specific
# port(s) only. By default group forwarding is `false`.
#
# `config.receiveStreams = [portNames]` feature makes the component expect
# substreams on specific inports instead of separate IPs (brackets and data).
# It makes select inports emit `Substream` objects on `data` event
# and silences `beginGroup` and `endGroup` events.
#
# `config.sendStreams = [portNames]` feature makes the component emit entire
# substreams of packets atomically to the outport. Atomically means that a
# substream cannot be interrupted by other packets, which is important when
# doing asynchronous processing. In fact, `sendStreams` is enabled by default
# on all outports when `config.async` is `true`.
#
# WirePattern supports both sync and async `proc` handlers. In latter case
# pass `config.async = true` and make sure that `proc` accepts callback as
# 4th parameter and calls it when async operation completes or fails.
#
# WirePattern sends group packets, sends data packets emitted by `proc`
# via its `outputPort` argument, then closes groups and disconnects
# automatically.
exports.WirePattern = (component, config, proc) ->
  # In ports
  inPorts = if 'in' of config then config.in else 'in'
  inPorts = [ inPorts ] unless inPorts instanceof Array
  # Out ports
  outPorts = if 'out' of config then config.out else 'out'
  outPorts = [ outPorts ] unless outPorts instanceof Array
  # Error port
  config.error = 'error' unless 'error' of config
  # For async process
  config.async = false unless 'async' of config
  # Keep correct output order for async mode
  config.ordered = false unless 'ordered' of config
  # Group requests by group ID
  config.group = false unless 'group' of config
  # Group requests by object field
  config.field = null unless 'field' of config
  # Forward group events from specific inputs to the output:
  # - false: don't forward anything
  # - true: forward unique groups of all inputs
  # - string: forward groups of a specific port only
  # - array: forward unique groups of inports in the list
  config.forwardGroups = false unless 'forwardGroups' of config
  # Receive streams feature
  config.receiveStreams = false unless 'receiveStreams' of config
  if typeof config.receiveStreams is 'string'
    config.receiveStreams = [ config.receiveStreams ]
  # Send streams feature
  config.sendStreams = false unless 'sendStreams' of config
  if typeof config.sendStreams is 'string'
    config.sendStreams = [ config.sendStreams ]
  config.sendStreams = outPorts if config.async
  # Parameter ports
  config.params = [] unless 'params' of config
  config.params = [ config.params ] if typeof config.params is 'string'
  # Node name
  config.name = '' unless 'name' of config

  collectGroups = config.forwardGroups
  # Collect groups from each port?
  if typeof collectGroups is 'boolean' and not config.group
    collectGroups = inPorts
  # Collect groups from one and only port?
  if typeof collectGroups is 'string' and not config.group
    collectGroups = [collectGroups]
  # Collect groups from any port, as we group by them
  if collectGroups isnt false and config.group
    collectGroups = true

  for name in inPorts
    unless component.inPorts[name]
      throw new Error "no inPort named '#{name}'"
    # Make the port required
    component.inPorts[name].options.required = true
  for name in outPorts
    unless component.outPorts[name]
      throw new Error "no outPort named '#{name}'"

  component.groupedData = {}
  component.groupedGroups = {}
  component.groupedDisconnects = {}

  disconnectOuts = ->
    # Manual disconnect forwarding
    for p in outPorts
      component.outPorts[p].disconnect() if component.outPorts[p].isConnected()

  # For ordered output
  component.outputQ = []
  processQueue = ->
    while component.outputQ.length > 0
      streams = component.outputQ[0]
      flushed = false
      # Null in the queue means "disconnect all"
      if streams is null
        disconnectOuts()
        flushed = true
      else
        # At least one of the outputs has to be resolved
        # for output streams to be flushed.
        if outPorts.length is 1
          tmp = {}
          tmp[outPorts[0]] = streams
          streams = tmp
        for key, stream of streams
          if stream.resolved
            flushed = flushed or stream.flush()
      component.outputQ.shift() if flushed
      return unless flushed

  if config.async
    component.load = 0 if 'load' of component.outPorts
    # Create before and after hooks
    component.beforeProcess = (outs) ->
      component.outputQ.push outs if config.ordered
      component.load++
      if 'load' of component.outPorts and component.outPorts.load.isAttached()
        component.outPorts.load.send component.load
        component.outPorts.load.disconnect()
    component.afterProcess = (err, outs) ->
      processQueue()
      component.load--
      if 'load' of component.outPorts and component.outPorts.load.isAttached()
        component.outPorts.load.send component.load
        component.outPorts.load.disconnect()

  # Parameter ports
  component.taskQ = []
  component.params = {}
  component.requiredParams = []
  component.completeParams = []
  component.defaultedParams = []
  component.defaultsSent = false

  sendDefaultParams = ->
    if component.defaultedParams.length > 0
      for param in component.defaultedParams
        tempSocket = InternalSocket.createSocket()
        component.inPorts[param].attach tempSocket
        tempSocket.send()
        tempSocket.disconnect()
        component.inPorts[param].detach tempSocket
    component.defaultsSent = true

  resumeTaskQ = ->
    if component.completeParams.length is component.requiredParams.length and
    component.taskQ.length > 0
      # Avoid looping when feeding the queue inside the queue itself
      temp = component.taskQ.slice 0
      component.taskQ = []
      while temp.length > 0
        task = temp.shift()
        task()
  for port in config.params
    unless component.inPorts[port]
      throw new Error "no inPort named '#{port}'"
    component.requiredParams.push port if component.inPorts[port].isRequired()
    component.defaultedParams.push port if component.inPorts[port].hasDefault()
  for port in config.params
    do (port) ->
      inPort = component.inPorts[port]
      inPort.process = (event, payload) ->
        # Param ports only react on data
        return unless event is 'data'
        component.params[port] = payload
        if component.completeParams.indexOf(port) is -1 and
        component.requiredParams.indexOf(port) > -1
          component.completeParams.push port
        # Trigger pending procs if all params are complete
        resumeTaskQ()

  # Disconnect event forwarding
  component.disconnectData = []
  component.disconnectQ = []

  # Grouped ports
  for port in inPorts
    do (port) ->
      # Support for StreamReceiver ports
      if config.receiveStreams and config.receiveStreams.indexOf(port) isnt -1
        inPort = new StreamReceiver component.inPorts[port]
      else
        inPort = component.inPorts[port]
      inPort.groups = []

      # Set processing callback
      inPort.process = (event, payload) ->
        switch event
          when 'begingroup'
            inPort.groups.push payload
          when 'endgroup'
            inPort.groups.pop()
          when 'disconnect'
            if inPorts.length is 1
              if config.async or config.StreamSender
                if config.ordered
                  component.outputQ.push null
                else
                  component.disconnectQ.push true
              else
                disconnectOuts()
            else
              foundGroup = false
              for i in [0...component.disconnectData.length]
                unless port of component.disconnectData[i]
                  foundGroup = true
                  component.disconnectData[i][port] = true
                  if Object.keys(component.disconnectData[i]).length is inPorts.length
                    component.disconnectData.shift()
                    if config.async or config.StreamSender
                      if config.ordered
                        component.outputQ.push null
                      else
                        component.disconnectQ.push true
                    else
                      disconnectOuts()
                  break
              unless foundGroup
                obj = {}
                obj[port] = true
                component.disconnectData.push obj

          when 'data'
            if inPorts.length is 1
              data = payload
              groups = inPort.groups
            else
              key = ''
              if config.group and inPort.groups.length > 0
                key = inPort.groups.toString()
                if config.group instanceof RegExp
                  key = '' unless config.group.test key
              else if config.field and typeof(payload) is 'object' and
              config.field of payload
                key = payload[config.field]

              needPortGroups = collectGroups instanceof Array and collectGroups.indexOf(port) isnt -1
              component.groupedData[key] = [] unless key of component.groupedData
              component.groupedGroups[key] = [] unless key of component.groupedGroups
              foundGroup = false
              requiredLength = inPorts.length
              ++requiredLength if config.field
              for i in [0...component.groupedData[key].length]
                unless port of component.groupedData[key][i]
                  foundGroup = true
                  component.groupedData[key][i][port] = payload
                  if needPortGroups
                    for grp in inPort.groups
                      if component.groupedGroups[key][i].indexOf(grp) is -1
                        component.groupedGroups[key][i].push grp
                  groupLength = Object.keys(component.groupedData[key][i]).length
                  if groupLength is requiredLength
                    data = (component.groupedData[key].splice i, 1)[0]
                    groups = (component.groupedGroups[key].splice i, 1)[0]
                    break
                  else
                    return # need more data to continue
              unless foundGroup
                obj = {}
                obj[config.field] = key if config.field
                obj[port] = payload
                component.groupedData[key].push obj
                if needPortGroups
                  component.groupedGroups[key].push inPort.groups
                else
                  component.groupedGroups[key].push []
                return # need more data to continue

            # Flush the data if the tuple is complete
            if collectGroups is true
              groups = inPort.groups

            # Reset port group buffers or it may keep them for next turn
            component.inPorts[p].groups = [] for p in inPorts

            # Prepare outputs
            outs = {}
            for name in outPorts
              if config.async or config.sendStreams and
              config.sendStreams.indexOf(name) isnt -1
                outs[name] = new StreamSender component.outPorts[name], config.ordered
              else
                outs[name] = component.outPorts[name]

            outs = outs[outPorts[0]] if outPorts.length is 1 # for simplicity

            whenDone = (err) ->
              if err
                component.error err, groups
              # For use with MultiError trait
              if typeof component.fail is 'function' and component.hasErrors
                component.fail()
              # Disconnect outputs if still connected,
              # this also indicates them as resolved if pending
              outputs = if outPorts.length is 1 then port: outs else outs
              disconnect = false
              if component.disconnectQ.length > 0
                component.disconnectQ.shift()
                disconnect = true
              for name, out of outputs
                out.endGroup() for g in groups if config.forwardGroups
                out.disconnect() if disconnect
                out.done() if config.async or config.StreamSender
              if typeof component.afterProcess is 'function'
                component.afterProcess err or component.hasErrors, outs

            # Before hook
            if typeof component.beforeProcess is 'function'
              component.beforeProcess outs

            # Sending defaults if not sent already
            sendDefaultParams() unless component.defaultsSent

            # Group forwarding
            if outPorts.length is 1
              outs.beginGroup g for g in groups if config.forwardGroups
            else
              for name, out of outs
                out.beginGroup g for g in groups if config.forwardGroups

            # Enforce MultiError with WirePattern (for group forwarding)
            exports.MultiError component, config.name, config.error, groups

            # Call the proc function
            if config.async
              postpone = ->
              resume = ->
              postponedToQ = false
              task = ->
                proc.call component, data, groups, outs, whenDone, postpone, resume
              postpone = (backToQueue = true) ->
                postponedToQ = backToQueue
                if backToQueue
                  component.taskQ.push task
              resume = ->
                if postponedToQ then resumeTaskQ() else task()
            else
              task = ->
                proc.call component, data, groups, outs
                whenDone()
            component.taskQ.push task
            resumeTaskQ()

  # Overload shutdown method to clean WirePattern state
  baseShutdown = component.shutdown
  component.shutdown = ->
    baseShutdown.call component
    component.groupedData = {}
    component.groupedGroups = {}
    component.outputQ = []
    component.disconnectData = []
    component.disconnectQ = []
    component.taskQ = []
    component.params = {}
    component.completeParams = []
    component.defaultedParams = []
    component.defaultsSent = false

  # Make it chainable or usable at the end of getComponent()
  return component

# Alias for compatibility with 0.5.3
exports.GroupedInput = exports.WirePattern


# `CustomError` returns an `Error` object carrying additional properties.
exports.CustomError = (message, options) ->
  err = new Error message
  return exports.CustomizeError err, options

# `CustomizeError` sets additional options for an `Error` object.
exports.CustomizeError = (err, options) ->
  for own key, val of options
    err[key] = val
  return err


# `MultiError` simplifies throwing and handling multiple error objects
# during a single component activation.
#
# `group` is an optional group ID which will be used to wrap all error
# packets emitted by the component.
exports.MultiError = (component, group = '', errorPort = 'error', forwardedGroups = []) ->
  component.hasErrors = false
  component.errors = []

  # Override component.error to support group information
  component.error = (e, groups = []) ->
    component.errors.push
      err: e
      groups: forwardedGroups.concat groups
    component.hasErrors = true

  # Fail method should be called to terminate process immediately
  # or to flush error packets.
  component.fail = (e = null, groups = []) ->
    component.error e, groups if e
    return unless component.hasErrors
    return unless errorPort of component.outPorts
    return unless component.outPorts[errorPort].isAttached()
    component.outPorts[errorPort].beginGroup group if group
    for error in component.errors
      component.outPorts[errorPort].beginGroup grp for grp in error.groups
      component.outPorts[errorPort].send error.err
      component.outPorts[errorPort].endGroup() for grp in error.groups
    component.outPorts[errorPort].endGroup() if group
    component.outPorts[errorPort].disconnect()
    # Clean the status for next activation
    component.hasErrors = false
    component.errors = []

  # Overload shutdown method to clear errors
  baseShutdown = component.shutdown
  component.shutdown = ->
    baseShutdown.call component
    component.hasErrors = false
    component.errors = []

  return component
