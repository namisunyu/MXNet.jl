# Autograd for NDArray
# this is a port of Python's autograd module
# https://github.com/apache/incubator-mxnet/blob/master/python/mxnet/autograd.py

###############################################################################
#  Private util functions
###############################################################################

"""
    _set_recording(state::Bool)::Bool

Set status to recording/not recording. When recording, graph will be constructed
for gradient computation.

## Parameters

* `state::Bool`

## Returns

Previous state before this set
"""
function _set_recording(state::Bool)::Bool
  prev = Ref{Cint}(C_NULL)
  @mxcall(:MXAutogradSetIsRecording, (Cint, Ref{Cint}), state, prev)
  prev[]
end

"""
Set status to training/predicting.
For example, Dropout will drop inputs randomly when
`train_mode=true` while simply passing through if `train_mode=false`.

## Parameters
* `train_mode::Bool`

## Returns

Previous state before this set.
"""
function _set_training(train_mode::Bool)::Bool
  prev = Ref{Cint}(C_NULL)
  @mxcall(:MXAutogradSetIsTraining, (Cint, Ref{Cint}), train_mode, prev)
  prev[]
end

"""
Get status on recording/not recording.

## Returns

Current state of recording.
"""
function _is_recording()::Bool
  state = Ref{Cint}(C_NULL)
  @mxcall(:MXAutogradIsRecording, (Ref{Cint},), state)
  state[]
end

"""
Get status on recording/not recording.

## Returns

Current state of recording.
"""
function _is_training()::Bool
  state = Ref{Cint}(C_NULL)
  @mxcall(:MXAutogradIsTraining, (Ref{Cint},), state)
  state[]
end

###############################################################################
#  Public API
###############################################################################

@inline function _record(f::Function, is_record::Union{Void, Bool},
                         train_mode::Union{Void, Bool})
  # Port from Python's `_RecordingStateScope` context manager
  # __enter__
  prev_is_record = _set_recording(is_record)
  prev_train_mode = _set_training(train_mode)

  try
    f()
  finally
    # __exit__
    if is_record != nothing && prev_is_record != is_record
      _set_recording(prev_is_record)
    end
    if train_mode != nothing && prev_train_mode != train_mode
      _set_recording(prev_train_mode)
    end
  end
end

"""
    record(f::Function)
    record() do
      ...
    end

Returns an autograd recording scope context to be used in `do` block
and captures code that needs gradients to be calculated.

.. note:: When forwarding with `train_mode=false`, the corresponding backward
          should also use `train_mode=false`, otherwise gradient is undefined.

## Example

```julia
# TBD
```

## Parameters

* `train_mode::Bool` (default is `true`)
  Whether the forward pass is in training or predicting mode.
  This controls the behavior of some layers such as `Dropout`, `BatchNorm`.
"""
record(f::Function, train_mode::Bool=true) = _record(f, true, train_mode)

"""
    pause(f::Function)
    pause() do
      ...
    end

Returns a scope context to be used in 'with' statement for codes that do not
need gradients to be calculated.

## Example (TBD)

```julia
record() do
  ...
  pause() do
    # testing, IO, gradient updates...
  end
end
```

## Parameters

* `train_mode::Bool` (default is `false`)
  Whether to do forward for training or predicting.
"""
pause(f::Function, train_mode::Bool=false) = _record(f, false, train_mode)

"""
    train_mode(f::Function)
    train_mode() do
      ...
    end

Returns a scope context to be used in 'with' statement in which forward pass
behavior is set to training mode, without changing the recording states.

## Example

```julia
y = model(x)
train_mode() do
  y = dropout(y)
end
```
"""
train_mode(f::Function) = _record(f, nothing, true)

"""
    predict_mode(f::Function)
    predict_mode() do
      ...
    end

Returns a scope context to be used in 'with' statement in which forward pass
behavior is set to inference mode, without changing the recording states.

## Example

```julia
record() do
  y = model(x)
  predict_mode() do
    y = sampling(y)
  end
end
```
"""
predict_mode(f::Function) = _record(f, nothing, false)

"""
    backward(head,  head_grad;  retain_graph=false, train_mode=true)
    backward(heads, head_grads; retain_graph=false, train_mode=true)

Compute the gradients of heads w.r.t previously marked variables.

## Parameters

- `head::NDArray`: output NDArray

- `head_grad::NDArray` or `Void`: gradient with respect to head.

- `heads::Vector{NDArray}`: a list of output NDArray

- `head_grads::Vector`: a list of gradient with respect ot heads.
  the element should be `NDArray` or `Void`

- `retain_graph::Bool`: whether to keep the graph after backward. e.g:
  If you want to differentiate the same graph twice,
  you need to pass `retain_graph=true`.

- `train_mode::Bool`: whether to do backward for training or predicting.
"""
backward(head::NDArray, head_grad::NDArray; kwargs...) =
  backward([head], [head_grad]; kwargs...)

backward(head::NDArray, head_grad::Void=nothing; kwargs...) =
  backward([head], head_grad; kwargs...)

function backward(heads::Vector{NDArray}, head_grads=Union{Vector, Void};
                  retain_graph::Bool=false, train_mode::Bool=true)
  output_handles = map(arr -> arr.handle, heads)

  if head_grads == nothing
    @mxcall(
      :MXAutogradBackwardEx,
      (MX_uint,
       Ptr{MX_handle},
       Ptr{MX_handle},
       MX_uint,
       Ptr{MX_handle},
       Cint,
       Cint,
       Cint,
       Ptr{MX_handle},
       Ptr{MX_handle}),
      length(output_handles),
      output_handles,
      C_NULL,
      0,
      C_NULL,
      retain_graph,
      false,  # create_graph
      train_mode,
      C_NULL,
      C_NULL)
    return
  end

  ograd_handles = map(head_grads) do arr
    if isa(arr, NDArray)
      arr.handle
    elseif isa(arr, Void)
      MX_handle(C_NULL)
    else
      throw(ArgumentError("element of head_grads should be NDArray or Void"))
    end
  end
  @assert length(output_handles) == length(ograd_handles)
  @mxcall(
    :MXAutogradBackwardEx,
    (MX_uint,
     Ptr{MX_handle},
     Ptr{MX_handle},
     MX_uint,
     Ptr{MX_handle},
     Cint,
     Cint,
     Cint,
     Ptr{MX_handle},
     Ptr{MX_handle}),
    length(output_handles),
    output_handles,
    ograd_handles,
    0,
    C_NULL,
    retain_graph,
    false,  # create_graph
    train_mode,
    C_NULL,
    C_NULL)
end

"""
    getgrad(arr::NDArray)

Returns the gradient buffer attached to this `NDArray`.
If the gradient buffer isn't attached yet, return `nothing`.
"""
function getgrad(arr::NDArray)
  out = Ref{mx.MX_handle}(C_NULL)
  @mxcall(:MXNDArrayGetGrad, (MX_handle, Ref{MX_handle}), arr.handle, out)
  (out[] == C_NULL) ? nothing: NDArray(MX_NDArrayHandle(out[]))
end

"""
    attach_grad(arr::NDArray, grad_req::Symbol=:write)

Attach a gradient buffer to this `NDArray`, so that [`backward`](@ref)
can compute gradient with respect to it.

## Parameters

- `arr::NDArray`
- `grad_req::Symbol` (default is `:write`)

## Return

The attached gradient buffer

## See also

- [`getgrad`](@ref)
"""
function attach_grad(arr::NDArray, grad_req::Symbol=:write)
  # TODO: support storage type (stype in Python)
  # TODO: make sure it works with gpu array
  grad = zeros_like(arr)
  _mark_variables([arr], [grad], grad_req)
  grad
end

"""
    mark_variables(var,  grad,  grad_req)
    mark_variables(vars, grads, grad_reqs)

Mark `NDArrays` as variables to compute gradient for autograd.

## Parameters

- `var::NDArray`
- `grad::NDArray`
- `grad_req::Symbol`: `:nop`, `:write`, `:inplace` or `:add`
- `vars::Vector{NDArray}`
- `grads::Vector{NDArray}`
- `grad_req::Vector{Symbol}`
"""
mark_variables(var::NDArray, grad::NDArray, grad_reqs::Symbol=:write) =
  _mark_variables([var], [grad], grad_reqs)

mark_variables(var::Vector{NDArray}, grads::Vector{NDArray}, grad_reqs=:write) =
  _mark_variables(var, grads, grad_reqs)

@inline function _mark_variables(vars::Vector{NDArray}, grads::Vector{NDArray},
                                 grad_reqs::Union{Vector{Symbol}, Symbol}=:write)
  if length(vars) != length(grads)
    throw(ArgumentError("number of variables and gradients not matched"))
  end


  var_hdls = map(arr -> arr.handle, vars)
  grad_hdls = map(arr -> arr.handle, grads)

  if isa(grad_reqs, Symbol)
    val = get(grad_req_map, grad_reqs, false)
    if val == false
      throw(ArgumentError("invalid grad_reqs $grad_reqs"))
    end

    grad_reqs = MX_uint[val for i ∈ 1:length(vars)]
  else
    if length(vars) != length(grad_reqs)
      throw(ArgumentError("number of variables and gradients not matched"))
    end

    grad_reqs = map(grad_reqs) do k
      val = get(grad_req_map, k, false)
      if val == false
        throw(ArgumentError("invalid grad_reqs $k"))
      end

      MX_uint(val)
    end
  end

  @mxcall(:MXAutogradMarkVariables,
          (MX_uint, Ref{MX_handle}, Ptr{MX_uint}, Ref{MX_handle}),
          length(vars), var_hdls, grad_reqs, grad_hdls)
end

"""
    getsymbol(arr)

Retrieve recorded computation history as `SymbolicNode`.

## Parameters

* `x::NDArray`: Array representing the head of computation graph.

## Returns

The retrieved `Symbol`.
 """
function getsymbol(arr::NDArray)
  ref = Ref{MX_handle}(C_NULL)
  @mxcall(:MXAutogradGetSymbol, (MX_handle, Ref{MX_handle}), arr, ref)
  SymbolicNode(MX_SymbolHandle(ref[]))
end

###############################################################################
#  TODO: User-defined differentiable function
###############################################################################