mutable struct Diagnostics
    accepted_alpha::Int64
    rejected_alpha::Int64

    accepted_mu::Vector{Int64}
    rejected_mu::Vector{Int64}

    accepted_lambda::Int64
    rejected_lambda::Int64

    accepted_flatL::Vector{Int64}
    rejected_flatL::Vector{Int64}

    accepted_nu::Int64
    rejected_nu::Int64

    accepted_split::Int64
    rejected_split::Int64

    accepted_merge::Int64
    rejected_merge::Int64

end

function Diagnostics(d)

    sizeflatL = Int64(d * (d + 1) / 2)

    return Diagnostics(
        0, 0, 
        zeros(Int64, d), zeros(Int64, d), 
        0, 0, 
        zeros(Int64, sizeflatL), zeros(Int64, sizeflatL), 
        0, 0, 
        0, 0, 
        0, 0)
end

function clear_diagnostics!(diagnostics::Diagnostics)
    diagnostics.accepted_alpha = 0
    diagnostics.rejected_alpha = 0

    diagnostics.accepted_mu = zeros(length(diagnostics.accepted_mu))
    diagnostics.rejected_mu = zeros(length(diagnostics.rejected_mu))

    diagnostics.accepted_lambda = 0
    diagnostics.rejected_lambda = 0

    diagnostics.accepted_flatL = zeros(length(diagnostics.accepted_flatL))
    diagnostics.rejected_flatL = zeros(length(diagnostics.rejected_flatL))

    diagnostics.accepted_nu = 0
    diagnostics.rejected_nu = 0

    diagnostics.accepted_split = 0
    diagnostics.rejected_split = 0

    diagnostics.accepted_merge = 0
    diagnostics.rejected_merge = 0

    return diagnostics
end
