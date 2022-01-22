using Revise
using ApproxFun, LinearAlgebra, Parameters, Setfield

using BifurcationKit, Plots
const BK = BifurcationKit

####################################################################################################
# specific methods for ApproxFun
import Base: eltype, similar, copyto!, length
import LinearAlgebra: mul!, rmul!, axpy!, axpby!, dot, norm

similar(x::ApproxFun.Fun, T) = (copy(x))
similar(x::ApproxFun.Fun) = copy(x)
mul!(w::ApproxFun.Fun, v::ApproxFun.Fun, α) = (w .= α * v)

eltype(x::ApproxFun.Fun) = eltype(x.coefficients)
length(x::ApproxFun.Fun) = length(x.coefficients)

dot(x::ApproxFun.Fun, y::ApproxFun.Fun) = sum(x * y)

# do not put y .= a .* x .+ y, this puts a lot of coefficients!
axpy!(a, x::ApproxFun.Fun, y::ApproxFun.Fun) = (y .= a * x + y)
axpby!(a::Float64, x::ApproxFun.Fun, b::Float64, y::ApproxFun.Fun) = (y .= a * x + b * y)
rmul!(y::ApproxFun.Fun, b::Float64) = (y.coefficients .*= b; y)
rmul!(y::ApproxFun.Fun, b::Bool) = b == true ? y : (y.coefficients .*= 0; y)

# copyto!(x::ApproxFun.Fun, y::ApproxFun.Fun) = ( copyto!(x.coefficients, y.coefficients);x)
copyto!(x::ApproxFun.Fun, y::ApproxFun.Fun) = ( (x.coefficients = copy(y.coefficients);x))

####################################################################################################

N(x; a = 0.5, b = 0.01) = 1 + (x + a * x^2) / (1 + b * x^2)
dN(x; a = 0.5, b = 0.01) = (1 - b * x^2 + 2 * a * x)/(1 + b * x^2)^2

function F_chan(u, p)
	@unpack α, β = p
	return [Fun(u(0.), domain(u)) - β,
			Fun(u(1.), domain(u)) - β,
			Δ * u + α * N(u, b = β)]
end

function dF_chan(u, v, p)
	@unpack α, β = p
	return [Fun(v(0.), domain(u)),
			Fun(v(1.), domain(u)),
			Δ * v + α * dN(u, b = β) * v]
end

function Jac_chan(u, p)
	@unpack α, β = p
	return [Evaluation(u.space, 0.),
			Evaluation(u.space, 1.),
			Δ + α * dN(u, b = β)]
end

function finalise_solution(z, tau, step, contResult)
	printstyled(color=:red,"--> AF length = ", (z, tau) .|> length ,"\n")
	chop!(z.u, 1e-14);chop!(tau.u, 1e-14)
	true
end

sol0 = Fun( x -> x * (1-x), Interval(0.0, 1.0))
const Δ = Derivative(sol0.space, 2);
par_af = (α = 3., β = 0.01)

optnew = NewtonPar(tol = 1e-12, verbose = true, linsolver = DefaultLS(useFactorization = false))
	sol, _, flag = @time BK.newton(
		F_chan, Jac_chan, sol0, par_af, optnew, normN = x -> norm(x, Inf64))
	# Plots.plot(out, label="Solution")

optcont = ContinuationPar(dsmin = 1e-4, dsmax = 0.05, ds= 0.01, pMax = 4.1, plotEveryStep = 10, newtonOptions = NewtonPar(tol = 1e-8, maxIter = 10, verbose = false), maxSteps = 300)

br0, = @time continuation(
	F_chan, Jac_chan, sol, par_af, (@lens _.α), optcont;
	plot = true,
	# tangentAlgo = MoorePenrosePred(), # this works VERY well
	linearAlgo = BorderingBLS(solver = optnew.linsolver, checkPrecision = false),
	plotSolution = (x, p; kwargs...) -> plot!(x; label = "l = $(length(x))", kwargs...),
		verbosity = 2,
	normC = x -> norm(x, Inf64))

plot(br0)
####################################################################################################
# Example with deflation technique
deflationOp = DeflationOperator(2, (x, y) -> dot(x, y), 1.0, [sol])
par_def = @set par_af.α = 3.3

optdef = setproperties(optnew; tol = 1e-9, maxIter = 1000)

solp = copy(sol)
	solp.coefficients .*= (1 .+ 0.41*rand(length(solp.coefficients)))

plot(sol);plot!(solp)

outdef1, _, flag = @time BK.newton(
	F_chan, Jac_chan,
	solp, par_def,
	optdef, deflationOp)
	flag && push!(deflationOp, outdef1)

plot(deflationOp.roots)
####################################################################################################
# other dot product
# dot(x::ApproxFun.Fun, y::ApproxFun.Fun) = sum(x * y) * length(x) # gives 0.1

optcont = ContinuationPar(dsmin = 0.001, dsmax = 0.05, ds= 0.01, pMax = 4.1, plotEveryStep = 10, newtonOptions = NewtonPar(tol = 1e-8, maxIter = 20, verbose = true), maxSteps = 300, theta = 0.2)

	br, _ = @time continuation(
		F_chan, Jac_chan, sol, par_af, (@lens _.α), optcont;
		dotPALC = (x, y) -> dot(x, y),
		plot = true,
		# finaliseSolution = finalise_solution,
		linearAlgo = BorderingBLS(solver = optnew.linsolver, checkPrecision = false),
		plotSolution = (x, p; kwargs...) -> plot!(x; label = "l = $(length(x))", kwargs...),
		verbosity = 2,
		# printsolution = x -> norm(x, Inf64),
		normC = x -> norm(x, Inf64))
####################################################################################################
# tangent predictor with Bordered system
br, _ = @time continuation(
	F_chan, Jac_chan, sol, par_af, (@lens _.α), optcont,
	tangentAlgo = BorderedPred(),
	linearAlgo = BorderingBLS(solver = optnew.linsolver, checkPrecision = false),
	plot = true,
	finaliseSolution = finalise_solution,
	plotSolution = (x, p;kwargs...)-> plot!(x; label = "l = $(length(x))", kwargs...))
####################################################################################################
# tangent predictor with Bordered system
# optcont = @set optcont.newtonOptions.verbose = true
indfold = 2
outfold, _, flag = @time newtonFold(
		F_chan, Jac_chan,
		br0, indfold, #index of the fold point
		options = NewtonPar(optcont.newtonOptions; verbose = true),
		bdlinsolver = BorderingBLS(solver = optnew.linsolver, checkPrecision = false))
	flag && printstyled(color=:red, "--> We found a Fold Point at α = ", outfold[end], ", β = 0.01, from ", br.specialpoint[indfold][3],"\n")
#################################################################################################### Continuation of the Fold Point using minimally augmented
indfold = 2

outfold, _, flag = @time newtonFold(
	(x, p) -> F_chan(x, p),
	(x, p) -> Jac_chan(x, p),
	(x, p) -> Jac_chan(x, p),
	br, indfold, #index of the fold point
	optcont.newtonOptions)
