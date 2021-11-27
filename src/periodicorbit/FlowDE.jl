using DiffEqBase: remake, solve, ODEProblem, EnsembleProblem, EnsembleThreads, DAEProblem, isinplace
####################################################################################################
# this function takes into accound a parameter passed to the vector field
# Putting the options `save_start = false` seems to give bugs with Sundials
function flowTimeSol(x, p, tm, pb::ODEProblem; alg = Euler(), kwargs...)
	_prob = remake(pb; u0 = x, tspan = (zero(eltype(tm)), tm), p = p)
	# the use of concrete_solve makes it compatible with Zygote
	sol = solve(_prob, alg; save_everystep = false, kwargs...)
	return (t = sol.t[end], u = sol[end])
end

# this function is a bit different from the previous one as it is geared towards parallel computing of the flow.
function flowTimeSol(x::AbstractMatrix, p, tm, epb::EnsembleProblem; alg = Euler(), kwargs...)
	# modify the function which asigns new initial conditions
	# see docs at https://docs.sciml.ai/dev/features/ensemble/#Performing-an-Ensemble-Simulation-1
	_prob_func = (prob, ii, repeat) -> prob = remake(prob, u0 = x[:, ii], tspan = (zero(eltype(tm[ii])), tm[ii]), p = p)
	_epb = setproperties(epb, output_func = (sol, i) -> ((t = sol.t[end], u = sol[end]), false), prob_func = _prob_func)
	sol = solve(_epb, alg, EnsembleThreads(); trajectories = size(x, 2), save_everystep = false, kwargs...)
	# sol.u contains a vector of tuples (sol_i.t[end], sol_i[end])
	return sol.u
end

flow(x, p, tm, pb::ODEProblem; alg = Euler(), kwargs...) = flowTimeSol(x, p, tm, pb; alg = alg, kwargs...).u
flow(x, p, tm, pb::EnsembleProblem; alg = Euler(), kwargs...) = flowTimeSol(x, p, tm, pb; alg = alg, kwargs...)
flow(x, tm, pb::Union{ODEProblem, EnsembleProblem}; alg = Euler(), kwargs...) =  flow(x, nothing, tm, pb; alg = alg, kwargs...)
####################################################################################################
# function used to compute the derivative of the flow, so pb encodes the variational equation
function dflow(x::AbstractVector, p, dx, tm, pb::ODEProblem; alg = Euler(), kwargs...)
	n = length(x)
	_prob = remake(pb; u0 = vcat(x, dx), tspan = (zero(eltype(tm)), tm), p = p)
	# the use of concrete_solve makes it compatible with Zygote
	sol = solve(_prob, alg, save_everystep = false; kwargs...)[end]
	return (t = tm, u = sol[1:n], du = sol[n+1:end])
end

# same for Parallel computing
function dflow(x::AbstractMatrix, p, dx, tm, epb::EnsembleProblem; alg = Euler(), kwargs...)
	N = size(x,1)
	_prob_func = (prob, ii, repeat) -> prob = remake(prob, u0 = vcat(x[:, ii], dx[:, ii]), tspan = (zero(eltype(tm[ii])), tm[ii]), p = p)
	_epb = setproperties(epb, output_func = (sol,i) -> ((t = sol.t[end], u = sol[end][1:N], du = sol[end][N+1:end]), false), prob_func = _prob_func)
	sol = solve(_epb, alg, EnsembleThreads(); trajectories = size(x, 2), save_everystep = false, kwargs...)
	return sol.u
end

dflow(x, dx, tspan, pb::Union{ODEProblem, EnsembleProblem}; alg = Euler(), kwargs...) = dflow(x, nothing, dx, tspan, pb; alg = alg, kwargs...)
####################################################################################################
# this function takes into accound a parameter passed to the vector field
function dflow_fd(x, p, dx, tm, pb::ODEProblem; alg = Euler(), δ = 1e-9, kwargs...)
	sol1 = flow(x .+ δ .* dx, p, tm, pb; alg = alg, kwargs...)
	sol2 = flow(x 			, p, tm, pb; alg = alg, kwargs...)
	return (t = tm, u = sol2, du = (sol1 .- sol2) ./ δ)
end

function dflow_fd(x, p, dx, tm, pb::EnsembleProblem; alg = Euler(), δ = 1e-9, kwargs...)
	sol1 = flow(x .+ δ .* dx, p, tm, pb; alg = alg, kwargs...)
	sol2 = flow(x 			, p, tm, pb; alg = alg, kwargs...)
	return [(t = sol1[ii][1], u = sol2[ii][2], du = (sol1[ii][2] .- sol2[ii][2]) ./ δ) for ii = 1:size(x,2) ]
end
dflow_fd(x, dx, tm, pb::Union{ODEProblem, EnsembleProblem}; alg = Euler(), δ = 1e-9, kwargs...) = dflow_fd(x, nothing, dx, tm, pb; alg = alg, δ = δ, kwargs...)
####################################################################################################
# this gives access to the full solution, convenient for Poincaré shooting
# this function takes into accound a parameter passed to the vector field and returns the full solution from the ODE solver. This is useful in Poincare Shooting to extract the period.
function flowFull(x, p, tm, pb::ODEProblem; alg = Euler(), kwargs...)
	_prob = remake(pb; u0 = x, tspan = (zero(tm), tm), p = p)
	sol = solve(_prob, alg; kwargs...)
end

function flowFull(x, p, tm, epb::EnsembleProblem; alg = Euler(), kwargs...)
	_prob_func = (prob, ii, repeat) -> prob = remake(prob, u0 = x[:, ii], tspan = (zero(eltype(tm[ii])), tm[ii]), p = p)
	_epb = setproperties(epb, prob_func = _prob_func)
	sol = solve(_epb, alg, EnsembleThreads(); trajectories = size(x, 2), kwargs...)
end
flowFull(x, tm, pb::Union{ODEProblem, EnsembleProblem}; alg = Euler(), kwargs...) = flowFull(x, nothing, tm, pb; alg = alg, kwargs...)
####################################################################################################
"""
Creates a Flow variable based on a `prob::ODEProblem` and ODE solver `alg`. The vector field `F` has to be passed, this will be resolved in the future as it can be recovered from `prob`. Also, the derivative of the flow is estimated with finite differences.
"""
# this constructor takes into accound a parameter passed to the vector field
function Flow(prob::Union{ODEProblem, EnsembleProblem, DAEProblem}, alg; kwargs...)
	probserial = prob isa EnsembleProblem ? prob.prob : prob
	return Flow(F = getVectorField(prob),
		flow = (x, p, t; kw2...) -> flow(x, p, t, prob; alg = alg, kwargs..., kw2...),

		flowTimeSol = (x, p, t; kw2...) -> flowTimeSol(x, p, t, prob; alg = alg, kwargs..., kw2...),

		flowFull = (x, p, t; kw2...) -> flowFull(x, p, t, prob; alg = alg, kwargs..., kw2...),

		dflow = (x, p, dx, t; kw2...) -> dflow_fd(x, p, dx, t, prob; alg = alg, kwargs..., kw2...),

		# serial version of dflow. Used for the computation of Floquet coefficients
		dfSerial = (x, p, dx, t; kw2...) -> dflow_fd(x, p, dx, t, probserial; alg = alg, kwargs..., kw2...),

		flowSerial = (x, p, t; kw2...) -> flowTimeSol(x, p, t, probserial; alg = alg, kwargs..., kw2...),

		prob = prob, probMono = nothing, callback = get(kwargs, :callback, nothing)
		)
end

function Flow(prob1::Union{ODEProblem, EnsembleProblem}, alg1, prob2::Union{ODEProblem, EnsembleProblem}, alg2; kwargs...)
	probserial1 = prob1 isa EnsembleProblem ? prob1.prob : prob1
	probserial2 = prob2 isa EnsembleProblem ? prob2.prob : prob2
	return Flow(F = getVectorField(prob1),
		flow = (x, p, t; kw2...) -> flow(x, p, t, prob1, alg = alg1; kwargs..., kw2...),

		flowTimeSol = (x, p, t; kw2...) -> flowTimeSol(x, p, t, prob1; alg = alg1, kwargs..., kw2...),

		flowFull = (x, p, t; kw2...) -> flowFull(x, p, t, prob1, alg = alg1; kwargs..., kw2...),

		dflow = (x, p, dx, t; kw2...) -> dflow(x, p, dx, t, prob2; alg = alg2, kwargs..., kw2...),

		# serial version of dflow. Used for the computation of Floquet coefficients
		dfSerial = (x, p, dx, t; kw2...) -> dflow(x, p, dx, t, probserial2; alg = alg2, kwargs..., kw2...),

		flowSerial = (x, p, t; kw2...) -> flowTimeSol(x, p, t, probserial1; alg = alg1, kwargs..., kw2...),

		prob = prob1, probMono = prob2, callback = get(kwargs, :callback, nothing)
		)
end