mutable struct MNCRPChain

    # Current state of the partition over samples
    # from the Chinese Restaurant Process
    clusters::Vector{Cluster}
    # Current value of hyperparameters
    hyperparams::MNCRPHyperparams
    # Map from base data (ffjord) to original data
    base2original::Dict{Vector{Float64}, Vector{Float64}}

    # Standardization parameters
    data_zero::Vector{Float64}
    data_scale::Vector{Float64}

    # Some chains of interests
    nbclusters_chain::Vector{Int64}
    largestcluster_chain::Vector{Int64}
    hyperparams_chain::Vector{MNCRPHyperparams}
    logprob_chain::Vector{Float64}
    clusters_samples::CircularBuffer{Vector{Cluster}}
    hyperparams_samples::CircularBuffer{MNCRPHyperparams}

    # Maximum a-posteriori state and location
    map_clusters::Vector{Cluster}
    map_hyperparams::MNCRPHyperparams
    map_base2original::Dict{Vector{Float64}, Vector{Float64}}
    map_logprob::Float64
    map_idx::Int64

end

function Base.show(io::IO, chain::MNCRPChain)
    println(io, "MNCRPchain")
    println(io, "         dimensions: $(length(chain.hyperparams.mu))")
    println(io, "          #elements: $(sum(length.(chain.clusters)))")
    println(io, "       chain length: $(length(chain))")
    println(io, "  current #clusters: $(length(chain.clusters))")
    println(io, "    current logprob: $(round(last(chain.logprob_chain), digits=2)) (best $(round(maximum(chain.logprob_chain), digits=2)))")
    println(io, "   nb chain samples: $(length(chain.clusters_samples))/$(length(chain.clusters_samples.buffer))")
    println(io)
    println(io, "        last MAP at: $(chain.map_idx)")
    println(io, "   #clusters in MAP: $(length(chain.map_clusters))")
      print(io, "        MAP logprob: $(round(chain.map_logprob, digits=2))")
end

function MNCRPChain(filename::AbstractString)
    return JLD2.load(filename)["chain"]
end

function MNCRPChain(dataset::MNCRPDataset; chain_samples=200, strategy=:hot, ffjord_nn=nothing)
    chain = MNCRPChain(dataset.data, chain_samples=chain_samples, standardize=false, strategy=strategy, ffjord_nn=ffjord_nn)
    chain.data_zero = dataset.data_zero[:]
    chain.data_scale = dataset.data_scale[:]
    return chain
end

function MNCRPChain(dataset::Matrix{Float64}; standardize=true, chain_samples=100, strategy=:sequential, optimize=false, ffjord_nn=nothing)
    return MNCRPChain(eachrow(dataset), standardize=standardize, chain_samples=chain_samples, strategy=strategy, optimize=optimize, ffjord_nn=ffjord_nn)
end

function MNCRPChain(
    data::Vector{Vector{Float64}}; 
    standardize=true, 
    chain_samples=100, 
    strategy=:sequential, 
    optimize=false, 
    ffjord_nn=nothing)
    
    d = length(first(data))

    @assert all(length.(data) .== d)

    hyperparams = MNCRPHyperparams(d, ffjord_nn=ffjord_nn)
    hyperparams.alpha = 10.0 / log(length(data))

    clusters_samples = CircularBuffer{Vector{Cluster}}(chain_samples)
    hyperparams_samples = CircularBuffer{MNCRPHyperparams}(chain_samples)

    
    # Keep unique observations only in case we standardize
    data = Set{Vector{Float64}}(deepcopy(data))
    println("    Loaded $(length(data)) unique data points into chain")
    data = collect(data)

    original_data = data

    data_zero = zeros(d)
    data_scale = ones(d)
    if standardize
        data_zero = mean(data)
        data_scale = std(data)
        data = Vector{Float64}[(x .- data_zero) ./ data_scale for x in data]
    end

    if ffjord_nn !== nothing
        matdata = reduce(hcat, data)
        ffjord_model = FFJORD(hyperparams.nn, (0.0f0, 1.0f0), (d,), Tsit5(), ad=AutoForwardDiff())
        ret, _ = ffjord_model(matdata, hyperparams.nn_params, hyperparams.nn_state)
        data = collect.(eachcol(ret.z))
    end

    # Data should still be ordered correctly
    base2original = Dict{Vector{Float64}, Vector{Float64}}(data .=> original_data)

    chain = MNCRPChain(
        [], hyperparams, # clusters, hyperparams
        base2original,
        data_zero, data_scale, 
        [], [], [], [],
        clusters_samples, hyperparams_samples,
        [], deepcopy(hyperparams), deepcopy(base2original), # MAP clusters, MAP hyperparams, MAP base2original
        -Inf, 1 # MAP logprob, MAP index
        )


    # chain.original_data = Dict{Vector{Float64}, Vector{<:Real}}(k => v for (k, v) in zip(data, original_data))

    println("    Initializing clusters...")
    if strategy == :hot
        ##### 1st initialization method: fullseq
        chain.clusters = [Cluster(data)]
        for i in 1:10
            advance_gibbs!(chain.clusters, chain.hyperparams, temperature=1.2)
        end
    elseif strategy == :N
        chain.clusters = [Cluster([datum]) for datum in data]
    elseif strategy == :1
        chain.clusters = [Cluster(data)]
    elseif strategy == :sequential
        for element in data
            advance_gibbs!(element, chain.clusters, chain.hyperparams)
        end
    end
    if optimize
        println("    Initializing hyperparameters...")
        optimize_hyperparams!(chain.clusters, chain.hyperparams, verbose=true)
    end

    chain.nbclusters_chain = [length(chain.clusters)]
    chain.largestcluster_chain = [maximum(length.(chain.clusters))]
    chain.hyperparams_chain = [deepcopy(hyperparams)]

    chain.map_clusters = deepcopy(chain.clusters)
    lp = logprobgenerative(chain.clusters, chain.hyperparams, chain.base2original, hyperpriors=true, ffjord=true)
    chain.map_logprob = lp
    chain.logprob_chain = [lp]
    # map_hyperparams=hyperparams and map_idx=1 have already been 
    # specified when calling MNCRPChain, but let's be explicit
    chain.map_hyperparams = deepcopy(chain.hyperparams)
    chain.map_idx = 1

    chain.logprob_chain = [chain.map_logprob]

    return chain

end


alpha_chain(chain::MNCRPChain) = [p.alpha for p in chain.hyperparams_chain]
mu_chain(chain::MNCRPChain) = [p.mu[:] for p in chain.hyperparams_chain]
mu_chain(::Type{Matrix}, chain::MNCRPChain) = reduce(hcat, mu_chain(chain))
mu_chain(chain::MNCRPChain, i) = [p.mu[i] for p in chain.hyperparams_chain]
lambda_chain(chain::MNCRPChain) = [p.lambda for p in chain.hyperparams_chain]
function psi_chain(chain::MNCRPChain; flatten=false)
    if flatten
        return [MultivariateNormalCRP.flatten(LowerTriangular(p.psi)) for p in chain.hyperparams_chain]
    else
        return [p.psi[:, :] for p in chain.hyperparams_chain]
    end
end
psi_chain(::Type{Matrix}, chain::MNCRPChain) = reduce(hcat, psi_chain(chain, flatten=true))
psi_chain(::Type{Array}, chain::MNCRPChain) = reduce((x,y)->cat(x, y, dims=3), psi_chain(chain))
psi_chain(chain::MNCRPChain, i, j) = [p.psi[i, j] for p in chain.hyperparams_chain]

flatL_chain(chain::MNCRPChain) = [p.flatL[:] for p in chain.hyperparams_chain]
flatL_chain(::Type{Matrix}, chain::MNCRPChain) = reduce(hcat, flatL_chain(chain))
flatL_chain(chain::MNCRPChain, i) = [p.flatL[i] for p in chain.hyperparams_chain]

nu_chain(chain::MNCRPChain) = [p.nu for p in chain.hyperparams_chain]

logprob_chain(chain::MNCRPChain) = chain.logprob_chain[:]
nbclusters_chain(chain::MNCRPChain) = chain.nbclusters_chain[:]
largestcluster_chain(chain::MNCRPChain) = chain.largestcluster_chain[:]

nn_chain(chain::MNCRPChain) = [p.nn_params for p in chain.hyperparams_chain]
nn_chain(::Type{Matrix}, chain::MNCRPChain) = reduce(hcat, nn_chain(chain))

function elements(chain::MNCRPChain; destandardize=false)
    if !destandardize
        return Vector{Float64}[x for cluster in chain.clusters for x in cluster]
    else
        return Vector{Float64}[chain.data_scale .* x .+ chain.data_zero for cluster in chain.clusters for x in cluster]
    end
end

# function ess(param_chain::Vector{<:Number})
#     ac = autocor(param_chain, 1:length(param_chain)-1)
#     ac = ac[1:findfirst(x -> x < 0, ac)-1]
#     return length(param_chain) / (1 + 2 * sum(ac))
# end

# function ess(chain::MNCRPChain)
#     d = length(chain.hyperparams.mu)

#     alpha_ess = ess(alpha_chain(chain))
#     mu_ess = [ess(mu_chain(chain, i)) for i in 1:d]
#     lambda_ess = ess(lambda_chain(chain))
#     psi_ess = [ess(psi_chain(chain, i, j)) for i in 1:d, j in 1:d]
#     flatL_ess = [ess(flatL_chain(chain, i)) for i in 1:length(chain.hyperparams.flatL)]
#     nu_ess = ess(nu_chain(chain))
#     logprob_ess = ess(logprob_chain(chain))
#     nbclusters_ess = ess(nbclusters_chain(chain))
#     largestcluster_ess = ess(largestcluster_chain(chain))
#     min_ess = minimum(vcat([alpha_ess, 
#                             minimum(mu_ess),                             
#                             lambda_ess, 
#                             minimum(psi_ess),
#                             minimum(flatL_ess),
#                             nu_ess, 
#                             logprob_ess,
#                             nbclusters_ess,
#                             largestcluster_ess]))
    
#     println("         logprob ESS: $(round(logprob_ess, digits=1))")
#     println("       #clusters ESS: $(round(nbclusters_ess, digits=1))")
#     println(" largest cluster ESS: $(round(largestcluster_ess, digits=1))")
#     println("           alpha ESS: $(round(alpha_ess, digits=1))")
#     println("              mu ESS: $(round.(mu_ess, digits=1))")
#     println("          lambda ESS: $(round(lambda_ess, digits=1))")
#     println("             Psi ESS: $(round.(psi_ess, digits=1))")
#     println("           flatL ESS: $(round.(flatL_ess, digits=1))")
#     println("              nu ESS: $(round(nu_ess, digits=1))")
#     println("           alpha ESS: $(round(alpha_ess, digits=1))")
#     println()
#     println("             min ESS: $(round(min_ess, digits=1))")

# end


function burn!(chain::MNCRPChain, n::Int64=0; burn_map=true)

    if n >= length(chain.logprob_chain)
        @error("Can't burn the whole chain, n must be smaller than $(length(chain.logprob_chain))")
    end

    if n > 0

        chain.logprob_chain = chain.logprob_chain[n+1:end]
        chain.hyperparams_chain = chain.hyperparams_chain[n+1:end]
        chain.nbclusters_chain = chain.nbclusters_chain[n+1:end]
        chain.largestcluster_chain = chain.largestcluster_chain[n+1:end]

        if burn_map && chain.map_idx <= n        
            chain.map_clusters = deepcopy(chain.clusters)
            chain.map_hyperparams = deepcopy(chain.hyperparams)
            chain.map_base2original = deepcopy(chain.base2original)
            chain.map_logprob = logprobgenerative(map_clusters_attempt, map_hyperparams, chain.base2original, ffjord=true)
            chain.map_idx = length(chain.logprob_chain)
        else
            chain.map_idx -= n
        end
    end

    return chain

end

function Base.length(chain::MNCRPChain)
    return length(chain.logprob_chain)
end

function ess_rhat(chain::MNCRPChain; transform=false, burn=0, kwargs...)
    return ess_rhat(reshape(reduce(hcat, unpack.(chain.hyperparams_chain[burn+1:end], transform=transform))', (length(chain.hyperparams_chain[burn+1:end]), 1, 3 + length(chain.hyperparams.mu) + length(chain.hyperparams.flatL))); kwargs...)
end

function stats(chain::MNCRPChain; burn=0)
    println("MAP state")
    println(" log prob: $(chain.map_logprob)")
    println(" #cluster: $(length(chain.map_clusters))")
    println("    alpha: $(chain.map_hyperparams.alpha)")
    println("       mu: $(chain.map_hyperparams.mu)")
    println("   lambda: $(chain.map_hyperparams.lambda)")
    println("      psi:")
    display(chain.map_hyperparams.psi)
    println("       nu: $(chain.map_hyperparams.nu)")
    println()


    nbc = chain.nbclusters_chain[burn+1:end]
    ac = alpha_chain(chain)[burn+1:end]
    muc = mu_chain(chain)[burn+1:end]
    lc = lambda_chain(chain)[burn+1:end]
    psic = psi_chain(chain)[burn+1:end]
    nc = nu_chain(chain)[burn+1:end]

    println("Mean..")
    println(" #cluster: $(mean(nbc)) [$(percentile(nbc, 25)), $(percentile(nbc, 75))])")
    println("    alpha: $(mean(ac)) ± $(std(ac))")
    println("       mu: $(mean(muc)) ± $(std(muc))")
    println("   lambda: $(mean(lc)) ± $(std(lc))")
    println("      psi:")
    display(mean(psic))
    println("       nu: $(mean(nc)) ± $(std(nc))")
    println()
end