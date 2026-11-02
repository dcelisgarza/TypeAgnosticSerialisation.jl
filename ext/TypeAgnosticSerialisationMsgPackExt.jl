module TypeAgnosticSerialisationMsgPackExt

using TypeAgnosticSerialisation: TypeAgnosticSerialisation
import MsgPack

function TypeAgnosticSerialisation._render(::Val{:msgpack}, tree; kwargs...)
    return MsgPack.pack(_widen_float16!(tree); kwargs...)
end

# `unpack` returns MessagePack extension values as inert `MsgPack.Extension` objects; we
# never call `MsgPack.extdeserialize` (which runs `Serialization.deserialize`), so an
# extension value in an untrusted document only makes `decode` fail.
function TypeAgnosticSerialisation._parse(::Val{:msgpack}, bytes::AbstractVector{UInt8})
    return MsgPack.unpack(convert(Vector{UInt8}, bytes))
end

# MessagePack has no 16-bit float, and MsgPack.jl refuses `Float16`. Widen it to the
# exactly-equal `Float32`; `decode` narrows it back with `convert`. The tree is freshly
# built by `encode` inside `to_msgpack` and shared with nobody, so it is updated in place.
_widen_float16!(x) = x
_widen_float16!(x::Float16) = Float32(x)
function _widen_float16!(d::AbstractDict)
    map!(_widen_float16!, values(d))
    return d
end
function _widen_float16!(v::Vector{Any})
    map!(_widen_float16!, v, v)
    return v
end

end # module
