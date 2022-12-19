mutable struct MNCRPhyperparams
    alpha::Float64
    mu::Vector{Float64}
    lambda::Float64
    flatL::Vector{Float64}
    L::LowerTriangular{Float64, Matrix{Float64}}
    psi::Matrix{Float64}
    nu::Float64

    diagnostics::Diagnostics
end

function MNCRPhyperparams(alpha, mu, lambda, flatL, L, psi, nu)
    d = size(mu, 1)

    return MNCRPhyperparams(alpha, mu, lambda, flatL, L, psi, nu, Diagnostics(d))
end

function MNCRPhyperparams(alpha::Float64, mu::Vector{Float64}, lambda::Float64, flatL::Vector{Float64}, nu::Float64)
    d = size(mu, 1)
    flatL_d = Int64(d * (d + 1) / 2)
    if size(flatL, 1) != flatL_d
        error("Dimension mismatch, flatL should have length $flatL_d")
    end

    L = foldflat(flatL)
    psi = L * L'

    return MNCRPhyperparams(alpha, mu, lambda, flatL, L, psi, nu)
end

function MNCRPhyperparams(alpha::Float64, mu::Vector{Float64}, lambda::Float64, L::LowerTriangular{Float64}, nu::Float64)
    d = size(mu, 1)
    if !(d == size(L, 1))
        error("Dimension mismatch, L should have dimension $d x $d")
    end

    psi = L * L'
    flatL = flatten(L)

    return MNCRPhyperparams(alpha, mu, lambda, flatL, L, psi, nu)
end

function MNCRPhyperparams(alpha::Float64, mu::Vector{Float64}, lambda::Float64, psi::Matrix{Float64}, nu::Float64)
    d = size(mu, 1)
    if !(d == size(psi, 1) == size(psi, 2))
        error("Dimension mismatch, L should have dimension $d x $d")
    end

    L = cholesky(psi).L
    flatL = flatten(L)

    return MNCRPhyperparams(alpha, mu, lambda, flatL, L, psi, nu)
end

function MNCRPhyperparams(d::Int64)
    return MNCRPhyperparams(1.0, zeros(d), 1.0, LowerTriangular(diagm(fill(sqrt(0.1), d))), 1.0 * d)
end

function clear_diagnostics!(hyperparams::MNCRPhyperparams)
    d = size(hyperparams.mu, 1)

    hyperparams.diagnostics = Diagnostics(d)

    return hyperparams    
end


function ij(flat_k::Int64)
    i = Int64(ceil(1/2 * (sqrt(1 + 8 * flat_k) - 1)))
    j = Int64(flat_k - i * (i - 1)/2)
    return (i, j)
end

function flatten(L::LowerTriangular{Float64})
    
    d = size(L, 1)

    flatL = zeros(Int64(d * (d + 1) / 2))

    # Fortran flashbacks
    idx = 1
    for i in 1:d
        for j in 1:i
            flatL[idx] = L[i, j]
            idx += 1
        end
    end

    return flatL
end

function foldflat(flatL::Vector{Float64})
    
    n = size(flatL, 1)

    # Recover the dimension of a matrix
    # from the length of the vector
    # containing elements of the diag + lower triangular
    # part of the matrix. The condition is that
    # length of vector == #els diagonal + #els lower triangular part
    # i.e N == d + (d² - d) / 2 
    # Will fail at Int64() if this condition
    # cannot be satisfied for N and d integers
    # Basically d is the "triangular root"
    d = Int64((sqrt(1 + 8 * n) - 1) / 2)

    L = LowerTriangular(zeros(d, d))

    # The order is row major
    idx = 1
    for i in 1:d
        for j in 1:i
            L[i, j] = flatL[idx]
            idx += 1
        end
    end

    return L
end


function dimension(hyperparams::MNCRPhyperparams)
    @assert size(hyperparams.mu, 1) == size(hyperparams.psi, 1) == size(hyperparams.psi, 2) "Dimensions of mu (d) and psi (d x d) do not match"
    return size(hyperparams.mu, 1)
end

function flatL!(hyperparams::MNCRPhyperparams, value::Vector{Float64})
    d = dimension(hyperparams)
    if (2 * size(value, 1) != d * (d + 1))
        error("Dimension mismatch, value should have length $(Int64(d*(d+1)/2))")
    end
    hyperparams.flatL = deepcopy(value) # Just making sure?
    hyperparams.L = foldflat(hyperparams.flatL)
    hyperparams.psi = hyperparams.L * hyperparams.L'
end

function L!(hyperparams::MNCRPhyperparams, value::T) where {T <: AbstractMatrix{Float64}}
    d = dimension(hyperparams)
    if !(d == size(value, 1) == size(value, 2))
        error("Dimension mismatch, value shoud have size $d x $d")
    end
    hyperparams.L = LowerTriangular(value)
    hyperparams.flatL = flatten(hyperparams.L)
    hyperparams.psi = hyperparams.L * hyperparams.L'
end

function psi!(hyperparams::MNCRPhyperparams, value::Matrix{Float64})
    d = dimension(hyperparams)
    if !(d == size(value, 1) == size(value, 2))
        error("Dimension mismatch, value should have size $d x $d")
    end
    hyperparams.L = cholesky(value).L
    hyperparams.flatL = flatten(hyperparams._L)
    hyperparams.psi = value
end

function project_hyperparams(hyperparams::MNCRPhyperparams, proj::Matrix{Float64})
    proj_hp = deepcopy(hyperparams)
    proj_hp.mu = proj * proj_hp.mu
    proj_hp.psi = proj * proj_hp.psi * proj'
    return proj_hp
end

function project_hyperparams(hyperparams::MNCRPhyperparams, dims::Vector{Int64})
    d = size(hyperparams.mu, 1)
    return project_hyperparams(hyperparams, dims_to_proj(dims, d))
end