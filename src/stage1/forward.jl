partial(x::TangentBundle, i) = x.partials[i]
partial(x::TaylorBundle{1}, i) = x.coeffs[i]
partial(x::UniformBundle, i) = x.partial
partial(x::CompositeBundle{N, B}, i) where {N, B} = Tangent{B}(map(x->partial(x, i), x.tup)...)
partial(x::ZeroTangent, i) = ZeroTangent()
primal(x::AbstractTangentBundle) = x.primal
primal(z::ZeroTangent) = ZeroTangent()

first_partial(x::TangentBundle{1}) = getfield(getfield(x, :partials), 1)
first_partial(x::TaylorBundle{1}) = getfield(getfield(x, :coeffs), 1)
first_partial(x::UniformBundle) = getfield(x, :partial)
first_partial(x::CompositeBundle) = map(first_partial, getfield(x, :tup))

# TODO: Which version do we want in ChainRules?
function my_frule(args::ATB{1}...)
    frule(map(first_partial, args), map(primal, args)...)
end

# Fast path for some hot cases
my_frule(::ZeroBundle{1, typeof(frule)}, args::ATB{1}...) = nothing
my_frule(::ZeroBundle{1, typeof(my_frule)}, args::ATB{1}...) = nothing

(::∂☆{N})(::ZeroBundle{N, typeof(my_frule)}, ::ZeroBundle{N, ZeroBundle{1, typeof(frule)}}, args::ATB{N}...) where {N} = ZeroBundle{N}(nothing)
(::∂☆{N})(::ZeroBundle{N, typeof(my_frule)}, ::ZeroBundle{N, ZeroBundle{1, typeof(my_frule)}}, args::ATB{N}...) where {N} = ZeroBundle{N}(nothing)

shuffle_down(b::UniformBundle{N, B, U}) where {N, B, U} =
    UniformBundle{minus1(N), <:Any, U}(UniformBundle{1, B, U}(b.primal, b.partial), b.partial)

function shuffle_down(b::TangentBundle{N, B}) where {N, B}
    # N.B: This depends on the special properties of the canonical tangent index order
    TangentBundle{N-1}(
        TangentBundle{1}(b.primal, (partial(b, 1),)),
        ntuple(2^(N-1)-1) do i
            TangentBundle{1}(partial(b, 2*i), (partial(b, 2*i+1),))
        end)
end

function shuffle_down(b::TaylorBundle{N, B}) where {N, B}
    TaylorBundle{N-1}(
        TangentBundle{1}(b.primal, (b.coeffs[1],)),
        ntuple(N-1) do i
            TangentBundle{1}(b.coeffs[i], (b.coeffs[i+1],))
        end)
end

function shuffle_down(b::CompositeBundle{N, B}) where {N, B}
    z = CompositeBundle{N-1, CompositeBundle{1, B}}(
        (CompositeBundle{N-1, Tuple}(
            map(shuffle_down, b.tup)
        ),)
    )
    z
end

function shuffle_up(r::CompositeBundle{1})
    z₀ = primal(r.tup[1])
    z₁ = partial(r.tup[1], 1)
    z₂ = primal(r.tup[2])
    z₁₂ = partial(r.tup[2], 1)
    if z₁ == z₂
        return TaylorBundle{2}(z₀, (z₁, z₁₂))
    else
        return TangentBundle{2}(z₀, (z₁, z₂, z₁₂))
    end
end

function taylor_compatible(a::ATB{N}, b::ATB{N}) where {N}
    primal(b) === a[TaylorTangentIndex(1)] || return false
    return all(1:(N-1)) do i
        b[TaylorTangentIndex(i)] === a[TaylorTangentIndex(i+1)]
    end
end

# Check whether the tangent bundle element is taylor-like
isswifty(::TaylorBundle) = true
isswifty(::UniformBundle) = true
isswifty(b::CompositeBundle) = all(isswifty, b.tup)
isswifty(::Any) = false

function shuffle_up(r::CompositeBundle{N}) where {N}
    a, b = r.tup
    if isswifty(a) && isswifty(b) && taylor_compatible(a, b)
        return TaylorBundle{N+1}(primal(a),
            ntuple(i->i == N+1 ?
                b[TaylorTangentIndex(i-1)] : a[TaylorTangentIndex(i)],
            N+1))
    else
        return TangentBundle{N+1}(r.tup[1].primal,
            (r.tup[1].partials..., primal(b),
            ntuple(i->partial(b,i), 2^(N+1)-1)...))
    end
end

function shuffle_up(r::UniformBundle{N, B, U}) where {N, B, U}
    (a, b) = primal(r)
    if r.partial === b
        u = b
    elseif b == NoTangent() && U === ZeroTangent
        u = b
    else
        error()
    end
    UniformBundle{N+1}(a, u)
end
@ChainRulesCore.non_differentiable shuffle_up(r::UniformBundle)

struct ∂☆internal{N}; end
struct ∂☆shuffle{N}; end

shuffle_base(r) = TangentBundle{1}(r[1], (r[2],))

function (::∂☆internal{1})(args::AbstractTangentBundle{1}...)
    r = my_frule(args...)
    if r === nothing
        return ∂☆recurse{1}()(args...)
    else
        return shuffle_base(r)
    end
end

function (::∂☆shuffle{N})(args::AbstractTangentBundle{N}...) where {N}
    ∂☆p = ∂☆{minus1(N)}()
    ∂☆p(ZeroBundle{minus1(N)}(my_frule), map(shuffle_down, args)...)
end

function (::∂☆internal{N})(args::AbstractTangentBundle{N}...) where {N}
    r = ∂☆shuffle{N}()(args...)
    if primal(r) === nothing
        return ∂☆recurse{N}()(args...)
    else
        return shuffle_up(r)
    end
end
(::∂☆{N})(args::AbstractTangentBundle{N}...) where {N} = ∂☆internal{N}()(args...)

# Special case rules for performance
@Base.aggressive_constprop function (::∂☆{N})(f::ATB{N, typeof(getfield)}, x::TangentBundle{N}, s::AbstractTangentBundle{N}) where {N}
    s = primal(s)
    TangentBundle{N}(getfield(primal(x), s),
        map(x->lifted_getfield(x, s), x.partials))
end

@Base.aggressive_constprop function (::∂☆{N})(f::ATB{N, typeof(getfield)}, x::TaylorBundle{N}, s::AbstractTangentBundle{N}) where {N}
    s = primal(s)
    TaylorBundle{N}(getfield(primal(x), s),
        map(y->lifted_getfield(y, s), x.coeffs))
end

@Base.aggressive_constprop function (::∂☆{N})(::ATB{N, typeof(getfield)}, x::CompositeBundle{N}, s::AbstractTangentBundle{N, Int}) where {N}
    x.tup[primal(s)]
end

@Base.aggressive_constprop function (::∂☆{N})(::ATB{N, typeof(getfield)}, x::CompositeBundle{N, B}, s::AbstractTangentBundle{N, Symbol}) where {N, B}
    x.tup[Base.fieldindex(B, primal(s))]
end

@Base.aggressive_constprop function (::∂☆{N})(f::ATB{N, typeof(getfield)}, x::ATB{N}, s::ATB{N}, inbounds::ATB{N}) where {N}
    s = primal(s)
    TangentBundle{N}(getfield(primal(x), s, primal(inbounds)),
        map(x->lifted_getfield(x, s), x.partials))
end

@Base.aggressive_constprop function (::∂☆{N})(f::ATB{N, typeof(getfield)}, x::UniformBundle{N, <:Any, U}, s::AbstractTangentBundle{N}) where {N, U}
    UniformBundle{N,<:Any,U}(getfield(primal(x), primal(s)), x.partial)
end

@Base.aggressive_constprop function (::∂☆{N})(f::ATB{N, typeof(getfield)}, x::UniformBundle{N, <:Any, U}, s::AbstractTangentBundle{N}, inbounds::AbstractTangentBundle{N}) where {N, U}
    UniformBundle{N,<:Any,U}(getfield(primal(x), primal(s), primal(inbounds)), x.partial)
end

function (::∂☆{N})(f::ATB{N, typeof(tuple)}, args::AbstractTangentBundle{N}...) where {N}
    ∂vararg{N}()(args...)
end

struct FwdMap{N, T<:AbstractTangentBundle{N}}
    f::T
end
(f::FwdMap{N})(args::AbstractTangentBundle{N}...) where {N} = ∂☆{N}()(f.f, args...)

function (::∂☆{N})(::ZeroBundle{N, typeof(map)}, f::ATB{N}, tup::CompositeBundle{N, <:Tuple}) where {N}
    ∂vararg{N}()(map(FwdMap(f), tup.tup)...)
end

function (::∂☆{N})(::ZeroBundle{N, typeof(map)}, f::ATB{N}, args::ATB{N, <:AbstractArray}...) where {N}
    # TODO: This could do an inplace map! to avoid the extra rebundling
    rebundle(map(FwdMap(f), map(unbundle, args)...))
end

function (::∂☆{N})(::ZeroBundle{N, typeof(map)}, f::ATB{N}, args::ATB{N}...) where {N}
    ∂☆recurse{N}()(ZeroBundle{N, typeof(map)}(map), f, args...)
end


function (::∂☆{N})(f::ZeroBundle{N, typeof(ifelse)}, arg::ATB{N, Bool}, args::ATB{N}...) where {N}
    ifelse(arg.primal, args...)
end

struct FwdIterate{N, T<:AbstractTangentBundle{N}}
    f::T
end
function (f::FwdIterate)(arg::ATB{N}) where {N}
    r = ∂☆{N}()(f.f, arg)
    primal(r) === nothing && return nothing
    (∂☆{N}()(ZeroBundle{N}(getindex), r, ZeroBundle{N}(1)),
     primal(∂☆{N}()(ZeroBundle{N}(getindex), r, ZeroBundle{N}(2))))
end
function (f::FwdIterate)(arg::ATB{N}, st) where {N}
    r = ∂☆{N}()(f.f, arg, ZeroBundle{N}(st))
    primal(r) === nothing && return nothing
    (∂☆{N}()(ZeroBundle{N}(getindex), r, ZeroBundle{N}(1)),
     primal(∂☆{N}()(ZeroBundle{N}(getindex), r, ZeroBundle{N}(2))))
end

function (this::∂☆{N})(::ZeroBundle{N, typeof(Core._apply_iterate)}, iterate::ATB{N}, f::ATB{N}, args::ATB{N}...) where {N}
    Core._apply_iterate(FwdIterate(iterate), this, (f,), args...)
end

function (this::∂☆{N})(::ZeroBundle{N, typeof(iterate)}, t::CompositeBundle{N, <:Tuple}) where {N}
    r = iterate(t.tup)
    r === nothing && return ZeroBundle{N}(nothing)
    ∂vararg{N}()(r[1], ZeroBundle{N}(r[2]))
end

function (this::∂☆{N})(::ZeroBundle{N, typeof(iterate)}, t::CompositeBundle{N, <:Tuple}, a::ATB{N}, args::ATB{N}...) where {N}
    r = iterate(t.tup, primal(a), map(primal, args)...)
    r === nothing && return ZeroBundle{N}(nothing)
    ∂vararg{N}()(r[1], ZeroBundle{N}(r[2]))
end

function (this::∂☆{N})(::ZeroBundle{N, typeof(Base.indexed_iterate)}, t::CompositeBundle{N, <:Tuple}, i::ATB{N}) where {N}
    r = Base.indexed_iterate(t.tup, primal(i))
    ∂vararg{N}()(r[1], ZeroBundle{N}(r[2]))
end

function (this::∂☆{N})(::ZeroBundle{N, typeof(Base.indexed_iterate)}, t::CompositeBundle{N, <:Tuple}, i::ATB{N}, st1::ATB{N}, st::ATB{N}...) where {N}
    r = Base.indexed_iterate(t.tup, primal(i), primal(st1), map(primal, st)...)
    ∂vararg{N}()(r[1], ZeroBundle{N}(r[2]))
end

function (this::∂☆{N})(::ZeroBundle{N, typeof(Base.indexed_iterate)}, t::TangentBundle{N, <:Tuple}, i::ATB{N}, st::ATB{N}...) where {N}
    ∂vararg{N}()(this(ZeroBundle{N}(getfield), t, i), ZeroBundle{N}(primal(i) + 1))
end


function (this::∂☆{N})(::ZeroBundle{N, typeof(getindex)}, t::CompositeBundle{N, <:Tuple}, i::ZeroBundle) where {N}
    t.tup[primal(i)]
end

function (this::∂☆{N})(::ZeroBundle{N, typeof(typeof)}, x::ATB{N}) where {N}
    DNEBundle{N}(typeof(primal(x)))
end

function (this::∂☆{N})(f::ZeroBundle{N, Core.IntrinsicFunction}, args::ATB{N}...) where {N}
    ff = primal(f)
    if ff === Base.not_int
        DNEBundle{N}(ff(map(primal, args)...))
    else
        error("Missing rule for intrinsic function $ff")
    end
end
