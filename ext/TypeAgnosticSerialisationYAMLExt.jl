module TypeAgnosticSerialisationYAMLExt

using TypeAgnosticSerialisation: TypeAgnosticSerialisation
import YAML

# `YAML.write` quotes every string, so no string is re-read as a number, bool, date or
# null. It also never writes anchors/aliases.
function TypeAgnosticSerialisation._render(::Val{:yaml}, tree; kwargs...)
    return YAML.write(tree; kwargs...)
end

function TypeAgnosticSerialisation._parse(::Val{:yaml}, str::AbstractString)
    tree = YAML.load(String(str); dicttype = Dict{String,Any})
    _reject_aliases(tree, Base.IdSet{Any}())
    return tree
end

# YAML.jl resolves an alias to the *same* container object as its anchor. A handful of
# nested aliases ("billion laughs") is a tiny document whose tree `decode` would walk in
# exponential time. Our writer never emits aliases, so refuse any shared container. The
# walk stops at the first repeat, so it is linear in the document size.
function _reject_aliases(x, seen::Base.IdSet{Any})
    if x isa AbstractDict || x isa AbstractVector
        if x in seen
            error(
                "TypeAgnosticSerialisation: YAML anchors/aliases are not supported " *
                "(`to_yaml` never writes them).",
            )
        end
        push!(seen, x)
        for v in (x isa AbstractDict ? values(x) : x)
            _reject_aliases(v, seen)
        end
    end
    return nothing
end

end # module
