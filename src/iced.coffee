

#### Library generator
# 
# Generate three categories of objects:
#   intern -- for internal use only
#   compiletime -- for compiletime lookups
#   runtime -- for when it's actually run, either inlined or require'd
# 
# Eventually, we might want to call this generator to generate into
# different contexts (like back into inline code, but for now, we abandon
# this project).
#  
exports.generator = generator = (intern, compiletime, runtime) ->
  
  ##### Compile time
  #
  # Constants mainly for compile-time behavior, but some shared with the
  # runtime too.
  #
  compiletime.transform = (x, options) ->
    x.icedTransform options

  compiletime.const = C =
    k : "__iced_k"
    k_noop : "__iced_k_noop"
    param : "__iced_p_"
    ns: "iced"
    runtime : "runtime"
    Deferrals : "Deferrals"
    deferrals : "__iced_deferrals"
    fulfill : "_fulfill"
    b_while : "_break"
    t_while : "_while"
    c_while : "_continue"
    n_while : "_next"
    n_arg   : "__iced_next_arg"
    context : "context"
    defer_method : "defer"
    slot : "__slot"
    assign_fn : "assign_fn"
    autocb : "autocb"
    retslot : "ret"
    trace : "__iced_trace"
    passed_deferral : "__iced_passed_deferral"
    findDeferral : "findDeferral"
    lineno : "lineno"
    parent : "parent"
    filename : "filename"
    funcname : "funcname"
    catchExceptions : 'catchExceptions'
    runtime_modes : [ "node", "inline", "window", "none", "browserify" ]
    trampoline : "trampoline"

  #### runtime
  # 
  # Support and libraries for runtime behavior
  #
  intern.makeDeferReturn = (obj, defer_args, id, trace_template, multi) ->
  
    trace = {}
    for k,v of trace_template
      trace[k] = v
    trace[C.lineno] = defer_args?[C.lineno]
    
    ret = (inner_args...) ->
      defer_args?.assign_fn?.apply(null, inner_args)
      if obj
        o = obj
        obj = null unless multi
        o._fulfill id, trace
      else
        intern._warn "overused deferral at #{intern._trace_to_string trace}"
  
    ret[C.trace] = trace
      
    ret

  #### Tick Counter
  #  count off every mod processor ticks
  # 
  intern.__c = 0

  intern.tickCounter = (mod) ->
    intern.__c++
    if (intern.__c % mod) == 0
      intern.__c = 0
      true
    else
      false

  #### Trace management and debugging
  #
  intern.__active_trace = null

  intern._trace_to_string = (tr) ->
    fn = tr[C.funcname] || "<anonymous>"
    "#{fn} (#{tr[C.filename]}:#{tr[C.lineno] + 1})"

  intern._warn = (m) ->
    console?.log "ICED warning: #{m}"

  ####
  # 
  # trampoline --- make a call to the next continuation...
  #   we can either do this directly, or every 500 ticks, from the
  #   main loop (so we don't overwhelm ourselves for stack space)..
  # 
  runtime.trampoline = (fn) ->
    if not intern.tickCounter 500
      fn()
    else if process?
      process.nextTick fn
    else
      setTimeout fn
    
  #### Deferrals
  #
  #   A collection of Deferrals; this is a better version than the one
  #   that's inline; it allows for iced tracing
  #

  runtime.Deferrals = class Deferrals

    constructor: (k, @trace) ->
      @continuation = k
      @count = 1
      @ret = null

    _call : (trace) ->
      if @continuation
        intern.__active_trace = trace
        c = @continuation
        @continuation = null
        c @ret
      else
        intern._warn "Entered dead await at #{intern._trace_to_string trace}"

    _fulfill : (id, trace) ->
      if --@count > 0
        # noop
      else
        runtime.trampoline ( () => @_call trace )
      
    defer : (args) ->
      @count++
      self = this
      return intern.makeDeferReturn self, args, null, @trace

    # As above, but won't get rewritten bythe compiler...
    # This is in case custom defer implementations want to
    # access the base implementation.
    _defer : (args) -> @["defer"] args

  #### findDeferral
  #
  # Search an argument vector for a deferral-generated callback

  runtime.findDeferral = findDeferral = (args) ->
    for a in args
      return a if a?[C.trace]
    null

  #### Rendezvous
  #
  # More flexible runtime behavior, can wait for the first deferral
  # to fire, rather than just the last.

  runtime.Rendezvous = class Rendezvous
    constructor: ->
      @completed = []
      @waiters = []
      @defer_id = 0

    # RvId -- A helper class the allows deferalls to take on an ID
    # when used with Rendezvous
    class RvId
      constructor: (@rv,@id,@multi)->
      defer: (defer_args) ->
        @rv._deferWithId @id, defer_args, @multi

    # Public interface
    # 
    # The public interface has 3 methods --- wait, defer and id
    # 
    wait: (cb) ->
      if @completed.length
        x = @completed.shift()
        cb(x)
      else
        @waiters.push cb

    defer: (defer_args) ->
      id = @defer_id++
      @deferWithId id, defer_args

    # id -- assign an ID to a deferral, and also toggle the multi
    # bit on the deferral.  By default, this bit is off.
    id: (i, multi) ->
      multi = false unless multi?
      new RvId(this, i, multi)
  
    # Private Interface
  
    _fulfill: (id, trace) ->
      if @waiters.length
        cb = @waiters.shift()
        cb id
      else
        @completed.push id
  
    _deferWithId: (id, defer_args, multi) ->
      @count++
      intern.makeDeferReturn this, defer_args, id, {}, multi

  #### stackWalk
  #
  # Follow an iced-generated stack walk from the active trace
  # up as far as we can. Output a vector of stack frames.
  #
  runtime.stackWalk = stackWalk = (cb) ->
    ret = []
    tr = if cb then cb[C.trace] else intern.__active_trace
    while tr
      line = "   at #{intern._trace_to_string tr}"
      ret.push line
      tr = tr?[C.parent]?[C.trace]
    ret

  #### exceptionHandler
  #
  # An exception handler that triggers the above iced stack walk
  # 

  runtime.exceptionHandler = exceptionHandler = (err, logger) ->
    logger = console.log unless logger
    logger err.stack
    stack = stackWalk()
    if stack.length
      logger "Iced callback trace:"
      logger stack.join "\n"
 

  #### catchExceptions
  # 
  # Catch all uncaught exceptions with the iced exception handler.
  # As mentioned here:
  #
  #    http://debuggable.com/posts/node-js-dealing-with-uncaught-exceptions:4c933d54-1428-443c-928d-4e1ecbdd56cb 
  # 
  # It's good idea to kill the service at this point, since state
  # is probably horked. See his examples for more explanations.
  # 
  runtime.catchExceptions = (logger) ->
    process?.on 'uncaughtException', (err) ->
      exceptionHandler err, logger
      process.exit 1

#### Exported items

exports.runtime = {}
generator this, exports, exports.runtime

