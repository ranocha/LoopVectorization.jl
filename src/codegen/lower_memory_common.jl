function parentind(ind::Symbol, op::Operation)
    for (id,opp) ∈ enumerate(parents(op))
        name(opp) === ind && return id
    end
    -1
end
function symbolind(ind::Symbol, op::Operation, td::UnrollArgs)
    id = parentind(ind, op)
    id == -1 && return ind, op
    @unpack u₁, u₁loopsym, u₂loopsym, vloopsym, u₂max, suffix = td
    parent = parents(op)[id]
    pvar, u₁op, u₂op = variable_name_and_unrolled(parent, u₁loopsym, u₂loopsym, vloopsym, suffix)
    Symbol(pvar, '_', Core.ifelse(u₁op, u₁, 1)), parent
end

staticexpr(x::Int) = Expr(:call, Expr(:curly, lv(:Static), x))
staticexpr(x::Union{Symbol,Expr}) = Expr(:call, lv(:Static), x)
maybestatic(x::Int) = staticexpr(x)
maybestatic(x::Union{Symbol,Expr}) = x

_MMind(ind::Union{Symbol,Expr}, str::Int) = Expr(:call, lv(:MM), VECTORWIDTHSYMBOL, ind, staticexpr(str))
_MMind(ind::Int, str::Int) = Expr(:call, lv(:MM), VECTORWIDTHSYMBOL, staticexpr(ind), staticexpr(str))

_MMind(ind::Union{Int,Symbol,Expr}, str::Union{Symbol,Expr}) = addexpr(mulexpr(_MMind(0,1),str),ind)
_MMind(ind, str::MaybeKnown) = isknown(str) ? _MMind(ind, gethint(str)) : _MMind(ind, getsym(str))

_iszero(::Symbol) = false
_iszero(::Expr) = false
_iszero(x) = iszero(x)
_isone(::Symbol) = false
_isone(::Expr) = false
_isone(x) = isone(x)
# To make this code type stable, despite potentially pushing `Int`s, `Symbol`s, or `Expr`s into `ret`,
# it takes the form of nested calls, each branching and popping off an argument.
function addoffset!(ret::Expr, stride, ind) # 3 args
    if _iszero(stride)
        pushexpr!(ret, ind)
    else
        pushexpr!(ret, _MMind(ind, stride))
    end
    nothing
end
# dropping `calcbypointeroffset` has to be delayed until after multiplying the `indexstride` by `index.
function addoffset!(ret::Expr, stride, ind, offset, calcbypointeroffset::Bool) # 5 -> 3 args
    if calcbypointeroffset
        addoffset!(ret, stride, offset)
    elseif _iszero(offset)
        addoffset!(ret, stride, ind)
    else
        addoffset!(ret, stride, addexpr(ind, offset))
    end
end
function _addoffset!(ret::Expr, vloopstride, indexstride, index, offset, calcbypointeroffset::Bool) # 6 -> 5 args
    if _isone(indexstride)
        addoffset!(ret, vloopstride, index, offset, calcbypointeroffset)
    elseif isknown(vloopstride) & isknown(indexstride)
        addoffset!(ret, gethint(vloopstride)*gethint(indexstride), index, offset, calcbypointeroffset)
    else
        addoffset!(ret, mulexpr(vloopstride,indexstride), index, offset, calcbypointeroffset)
    end
end
# multiply `index` by `indexstride`
function addoffset!(ret::Expr, vloopstride, indexstride, index, offset, calcbypointeroffset::Bool) # 6 -> (5 or 6) args
    if _isone(indexstride)
        addoffset!(ret, vloopstride, index, offset, calcbypointeroffset) # 5
    elseif calcbypointeroffset # `ind` is getting dropped, no need to allocate via `mulexpr`
        _addoffset!(ret, vloopstride, indexstride, index, offset, calcbypointeroffset) # 6
    else # multiply index by stride
        _addoffset!(ret, vloopstride, indexstride, mulexpr(index, indexstride), offset, calcbypointeroffset) # 6
    end
end


function addoffset!(ret::Expr, indvectorized::Bool, vloopstride, indexstride, index, offset, calcbypointeroffset::Bool) # 7 -> (5 or 6) args
    if indvectorized
        addoffset!(ret, vloopstride, indexstride, index, offset, calcbypointeroffset)
    elseif _isone(indexstride)
        addoffset!(ret, 0, index, offset, calcbypointeroffset)
    else
        addoffset!(ret, 0, lazymulexpr(index, indexstride), offset, calcbypointeroffset)
    end
end

function addvectoroffset!(ret::Expr, indvectorized::Bool, unrolledsteps, vloopstride, indexstride, index, offset, calcbypointeroffset::Bool) # 8 -> 7 args
    # if _iszero(unrolledsteps) # if no steps, pass through; should be unreachable
    #     addoffset!(ret, indvectorized, vloopstride, indexstride, index, offset, calcbypointeroffset)
    # else
    if calcbypointeroffset # if we previously would've dropped the index, we now replace it with the `VECTORWIDTH` step
        if _isone(unrolledsteps)
            addoffset!(ret, indvectorized, vloopstride, indexstride, VECTORWIDTHSYMBOL, offset, false)
        else
            addoffset!(ret, indvectorized, vloopstride, indexstride, mulexpr(VECTORWIDTHSYMBOL,unrolledsteps), offset, false)
        end
    elseif _isone(unrolledsteps) # add the step to the index
        addoffset!(ret, indvectorized, vloopstride, indexstride, addexpr(VECTORWIDTHSYMBOL,index), offset, false)
    else
        addoffset!(ret, indvectorized, vloopstride, indexstride, addexpr(mulexpr(VECTORWIDTHSYMBOL,unrolledsteps),index), offset, false)
    end
end
# unrolledloopstride is a stride multiple on `unrolledsteps`
function addvectoroffset!(
    ret::Expr, mm::Bool, unrolledsteps::Int, unrolledloopstride, vloopstride, indexstride::Integer, index, offset::Integer, calcbypointeroffset::Bool, indvectorized::Bool
) # 10 -> (7 or 8) args
    if unrolledsteps == 0 # neither unrolledloopstride or indexstride can be 0
        addoffset!(ret, mm, vloopstride, indexstride, index, offset, calcbypointeroffset) # 7 arg
    elseif indvectorized
        unrolledsteps *= indexstride
        if isknown(unrolledloopstride)
            addvectoroffset!(ret, mm, gethint(unrolledloopstride)*unrolledsteps, vloopstride, indexstride, index, offset, calcbypointeroffset) # 8 arg
        elseif unrolledsteps == 1
            addvectoroffset!(ret, mm, unrolledloopstride, vloopstride, indexstride, index, offset, calcbypointeroffset) # 8 arg
        else
            addvectoroffset!(ret, mm, mulexpr(unrolledloopstride,unrolledsteps), vloopstride, indexstride, index, offset, calcbypointeroffset) # 8 arg
        end
    else
        addoffset!(ret, mm, vloopstride, indexstride, index, offset + unrolledsteps, calcbypointeroffset) # 7 arg
    end
end

"""
unrolled loads are calculated as offsets with respect to an initial gesp. This has proven important to helping LLVM generate efficient code in some cases.
Therefore, unrolled === true results in inds being ignored.
_mm means to insert `mm`s.
"""
function mem_offset(op::Operation, td::UnrollArgs, inds_calc_by_ptr_offset::Vector{Bool}, _mm::Bool)
    # @assert accesses_memory(op) "Computing memory offset only makes sense for operations that access memory."
    ret = Expr(:tuple)
    indices = getindicesonly(op)
    offsets = getoffsets(op)
    strides = getstrides(op)
    loopedindex = op.ref.loopedindex
    # inds_calc_by_ptr_offset = indices_calculated_by_pointer_offsets(ls, op.ref)
    @unpack vloopsym = td
    for (n,ind) ∈ enumerate(indices)
        indvectorized = _mm & (ind === vloopsym)
        offset = offsets[n] % Int
        stride = strides[n] % Int
        ind_by_offset = inds_calc_by_ptr_offset[n] | (ind === CONSTANTZEROINDEX)
        if !ind_by_offset
            offset += (stride - 1)
        end
        @unpack vstep = td
        if loopedindex[n]
            addoffset!(ret, indvectorized, vstep, stride, ind, offset, ind_by_offset) # 7 arg
        else
            offset -= 1
            newname, parent = symbolind(ind, op, td)
            # _mmi = indvectorized && parent !== op && (!isvectorized(parent))
            # addoffset!(ret, newname, stride, offset, _mmi)
            _mmi = indvectorized && parent !== op && (!isvectorized(parent))
            @assert !_mmi "Please file an issue with an example of how you got this."
            if isu₁unrolled(parent) & (td.u₁ > 1)
                gf = GlobalRef(Core,:getfield)
                firstnew = Expr(:call, gf, Expr(:call, gf, newname, 1), 1, false)
                if isvectorized(parent) & (!_mm)
                    firstnew = Expr(:call, lv(:unmm), firstnew)
                end
                addoffset!(ret, 0, firstnew, offset, false)
            else
                if isvectorized(parent) & (!_mm)
                    addoffset!(ret, 0, Expr(:call, lv(:unmm), newname), offset, false)
                else
                    addoffset!(ret, 0, newname, offset, false)
                end
            end
        end
    end
    ret
end
# function unrolled_curly(op::Operation, u₁::Int, u₁loopsym::Symbol, vectorized::Symbol, mask::Bool)

# interleave: `0` means `false`, positive means literal, negative means multiplier
function unrolled_curly(op::Operation, u₁::Int, u₁loop::Loop, vloop::Loop, mask::Bool, interleave::Int=0)
    u₁loopsym = u₁loop.itersymbol
    vloopsym = vloop.itersymbol
    indices = getindicesonly(op)
    vstep = step(vloop)
    li = op.ref.loopedindex
    # @assert all(loopedindex)
    # @unpack u₁, u₁loopsym, vloopsym = td
    # @show vptr(op), inds_calc_by_ptr_offset
    # isone(u₁) && return mem_offset_u(op, td, inds_calc_by_ptr_offset, true)
    AV = AU = -1
    for (n,ind) ∈ enumerate(indices)
        # @show AU, op, n, ind, vloopsym, u₁loopsym
        if li[n]
            if ind === vloopsym
                @assert AV == -1 # FIXME: these asserts should be replaced with checks that prevent using `unrolled_curly` in these cases (also to be reflected in cost modeling, to avoid those)
                AV = n
            end
            if ind === u₁loopsym
                @assert AU == -1
                AU = n
            end
        else
            opp = findop(parents(op), ind)
            # @show opp
            if isvectorized(opp)
                @assert AV == -1
                AV = n
            end
            if (u₁loopsym === CONSTANTZEROINDEX) ? (CONSTANTZEROINDEX ∈ loopdependencies(opp)) : (isu₁unrolled(opp))
                @assert AU == -1
                AU = n
            end
        end
    end
    # if AU == -1
    #     return mem_offset_u(op, td, inds_calc_by_ptr_offset, true)
    # end
    # ind = mem_offset_u(op, td, inds_calc_by_ptr_offset, false)
    vecnotunrolled = AU != AV
    conditional_memory_op = isconditionalmemop(op)
    if mask || conditional_memory_op
        M = one(UInt)
        # `isu₁unrolled(last(parents(op)))` === is condop unrolled?
        # isu₁unrolled(last(parents(op)))
        if vecnotunrolled || conditional_memory_op || (interleave > 0) # mask all
            M = (M << u₁) - M
        else # mask last
            M <<= (u₁ - 1)
        end
    else
        M = zero(UInt)
    end
    @assert isknown(step(u₁loop)) "Unrolled loops must have known steps to use `Unroll` type; this is a bug, shouldn't have reached here"
    if AV > 0
        @assert isknown(step(vloop)) "Vectorized loops must have known steps to use `Unroll` type; this is a bug, shouldn't have reached here."
        X = convert(Int, getstrides(op)[AV])
        X *= gethint(step(vloop))
        intvecsym = :(Int($VECTORWIDTHSYMBOL))
        if interleave > 0
            Expr(:curly, lv(:Unroll), AU, interleave, u₁, AV, intvecsym, M, X)
        elseif interleave < 0
            unrollstepexpr = :(Int($(mulexpr(VECTORWIDTHSYMBOL, -interleave))))
            Expr(:curly, lv(:Unroll), AU, unrollstepexpr, u₁, AV, intvecsym, M, X)
        else
            if vecnotunrolled
                # Expr(:call, Expr(:curly, lv(:Unroll), AU, 1, u₁, AV, intvecsym, M, 1), ind)
                Expr(:curly, lv(:Unroll), AU, gethint(step(u₁loop)), u₁, AV, intvecsym, M, X)
            else
                if isone(X)
                    Expr(:curly, lv(:Unroll), AU, intvecsym, u₁, AV, intvecsym, M, X)
                else
                    unrollstepexpr = :(Int($(mulexpr(VECTORWIDTHSYMBOL, X))))
                    Expr(:curly, lv(:Unroll), AU, unrollstepexpr, u₁, AV, intvecsym, M, X)
                end
            end
        end
    else
        Expr(:curly, lv(:Unroll), AU, gethint(step(u₁loop)), u₁, 0, 1, M, 1)
    end
end
function unrolledindex(op::Operation, td::UnrollArgs, mask::Bool, inds_calc_by_ptr_offset::Vector{Bool})
    @unpack u₁, u₁loopsym, u₁loop, vloop = td
    isone(u₁) && return mem_offset_u(op, td, inds_calc_by_ptr_offset, true)
    any(==(u₁loopsym), getindicesonly(op)) || return mem_offset_u(op, td, inds_calc_by_ptr_offset, true)

    unrollcurl = unrolled_curly(op, u₁, u₁loop, vloop, mask)
    ind = mem_offset_u(op, td, inds_calc_by_ptr_offset, false)
    Expr(:call, unrollcurl, ind)
end

function mem_offset_u(op::Operation, td::UnrollArgs, inds_calc_by_ptr_offset::Vector{Bool}, _mm::Bool, incr₁::Int = 0)
    @assert accesses_memory(op) "Computing memory offset only makes sense for operations that access memory."
    @unpack u₁loopsym, u₂loopsym, vloopsym, u₁step, u₂step, vstep, suffix = td

    #u₁
    incr₂ = max(suffix, 0)#(suffix == -1) ? 0 : suffix
    ret = Expr(:tuple)
    indices = getindicesonly(op)
    offsets = getoffsets(op)
    strides = getstrides(op)
    # allbasezero = all(inds_calc_by_ptr_offset) && all(iszero, offsets)
    loopedindex = op.ref.loopedindex
    if iszero(incr₁) & iszero(incr₂)
        return mem_offset(op, td, inds_calc_by_ptr_offset, _mm)
        # append_inds!(ret, indices, loopedindex)
    else
        for (n,ind) ∈ enumerate(indices)
            ind_by_offset = inds_calc_by_ptr_offset[n] | (ind === CONSTANTZEROINDEX)
            offset = convert(Int, offsets[n])
            stride = convert(Int, strides[n])
            indvectorized = ind === vloopsym
            indvectorizedmm = _mm & indvectorized
            if !ind_by_offset
                offset += (stride - 1)
            end
            if ind === u₁loopsym
                addvectoroffset!(ret, indvectorizedmm, incr₁, u₁step, vstep, stride, ind, offset, ind_by_offset, indvectorized) # 9 arg
            elseif ind === u₂loopsym
                # if isstore(op)
                #     @show indvectorized, ind === vloopsym, u₂loopsym, incr₂
                # end
                addvectoroffset!(ret, indvectorizedmm, incr₂, u₂step, vstep, stride, ind, offset, ind_by_offset, indvectorized) # 9 arg
            elseif loopedindex[n]
                addoffset!(ret, indvectorizedmm, vstep, stride, ind, offset, ind_by_offset) # 7 arg
            else
                offset -= 1
                newname, parent = symbolind(ind, op, td)
                _mmi = indvectorizedmm && parent !== op && (!isvectorized(parent))
                #                              addoffset!(ret, newname, 1, offset, _mmi)
                @assert !_mmi "Please file an issue with an example of how you got this."
                if isvectorized(parent) & (!_mm)
                    if isu₁unrolled(parent) & (td.u₁ > 1)
                        gf = GlobalRef(Core,:getfield)
                        newname_unmm = Expr(:call, lv(:unmm), Expr(:call, gf, Expr(:call, gf, newname, 1), incr₁+1, false))
                    else
                        newname_unmm = Expr(:call, lv(:unmm), newname)
                    end
                    if stride ≠ 1
                        newname_unmm = mulexpr(newname_unmm,stride)
                    end
                    addoffset!(ret, 0, newname_unmm, offset, false)
                elseif isu₁unrolled(parent) & (td.u₁ > 1)
                    gf = GlobalRef(Core,:getfield)
                    firstnew = Expr(:call, gf, Expr(:call, gf, newname, 1), incr₁+1, false)
                    if stride ≠ 1
                        firstnew = mulexpr(firstnew,stride)
                    end
                    addoffset!(ret, 0, firstnew, offset, false)
                elseif stride == 1
                    addoffset!(ret, 0, newname, offset, false)
                else
                    addoffset!(ret, 0, mulexpr(newname,stride), offset, false)
                end
            end
        end
    end
    ret
end

@inline and_last(a, b) = a & b
@generated function and_last(v::VecUnroll{N}, m) where {N}
    q = Expr(:block, Expr(:meta,:inline), :(vd = data(v)))
    t = Expr(:call, lv(:promote))
    gf = GlobalRef(Core, :getfield)
    for n ∈ 1:N
        push!(t.args, :($gf(vd, $n, false)))
    end
    push!(t.args, :($gf(vd, $(N+1), false) & m))
    push!(q.args, Expr(:call, lv(:VecUnroll), t))
    q
end


isconditionalmemop(op::Operation) = (instruction(op).instr === :conditionalload) || (instruction(op).instr === :conditionalstore!)
function add_memory_mask!(memopexpr::Expr, op::Operation, td::UnrollArgs, mask::Bool)
    @unpack u₁, u₁loopsym, u₂loopsym, vloopsym, u₂max, suffix = td
    if isconditionalmemop(op)
        condop = last(parents(op))
        opu₂ = (suffix ≠ -1) && isu₂unrolled(op)
        condvar, condu₁unrolled = condvarname_and_unroll(condop, u₁loopsym, u₂loopsym, vloopsym, suffix, opu₂)
        # if it isn't unrolled, then `m`
        u = condu₁unrolled ? u₁ : 1
        # u = isu₁unrolled(condop) ? u₁ : 1
        condvar = Symbol(condvar, '_', u)
        # If we need to apply `MASKSYMBOL` and the condvar
        # 2 condvar possibilities:
        #   `VecUnroll` applied everywhere
        #    single mask "broadcast"
        # 2 mask possibilities
        #    u₁loopsym ≠  vloopsym, and we mask all
        #    u₁loopsym == vloopsym, and we mask last
        # broadcast both, so can do so implicitly
        # this is true whether or not `condbroadcast`
        if !mask || (!isvectorized(op))
            push!(memopexpr.args, condvar)
        elseif (u₁loopsym ≢ vloopsym) | (u₁ == 1) # mask all equivalenetly
            push!(memopexpr.args, Expr(:call, lv(:&), condvar, MASKSYMBOL))
            # if the condition `(u₁loopsym ≢ vloopsym) | (u₁ == 1)` failed, we need to apply `MASKSYMBOL` only to last unroll.
        elseif !condu₁unrolled && isu₁unrolled(op) # condbroadcast
            # explicitly broadcast `condvar`, and apply `MASKSYMBOL` to end
            t = Expr(:call, lv(:promote))
            for um ∈ 1:u₁-1
                push!(t.args, condvar)
            end
            push!(t.args, Expr(:call, lv(:&), condvar, MASKSYMBOL))
            push!(memopexpr.args, Expr(:call, lv(:VecUnroll), t))
        else# !condbroadcast && !vecunrolled
            push!(memopexpr.args, Expr(:call, lv(:and_last), condvar, MASKSYMBOL))
        end
    elseif mask && isvectorized(op)
        push!(memopexpr.args, MASKSYMBOL)
    end
    nothing
end

varassignname(var::Symbol, u::Int, isunrolled::Bool) = isunrolled ? Symbol(var, u) : var
# name_memoffset only gets called when vectorized
function name_memoffset(var::Symbol, op::Operation, td::UnrollArgs, u₁unrolled::Bool, inds_calc_by_ptr_offset::Vector{Bool})
    @unpack u₁, u₁loopsym, u₂loopsym, suffix = td
    if (suffix == -1) && u₁ < 0 # u₁ == -1 sentinel value meaning not unrolled
        name = var
        mo = mem_offset(op, td, inds_calc_by_ptr_offset, true)
    else
        name = u₁unrolled ? Symbol(var, u₁) : var
        mo = mem_offset_u(op, td, inds_calc_by_ptr_offset)
    end
    name, mo
end

function condvarname_and_unroll(cond::Operation, u₁loop::Symbol, u₂loop::Symbol, vloop::Symbol, suffix::Int, opu₂::Bool)
    condvar, condu₁, condu₂ = variable_name_and_unrolled(cond, u₁loop, u₂loop, vloop, Core.ifelse(opu₂, suffix, -1))
    condvar, condu₁
end
