## Block IHT INEXACT for NO common support problem with strength sharing (problem (3) in the write-up)
## has different supports for active sets!!
## b: n*K observation matrix
## A: n*p*K data tensor
## s: Sparsity level (integer)
## x0: p*K initial solution
## lambda1>=0 the ridge coefficient
## lambda2>=0 the strength sharing coefficient
## lambda_z>=0 the strength sharing coefficient for support

using TSVD, Statistics #, LinearAlgebra, Statistics

include("BlockComIHT_inexact_diffAS_optTest_MT.jl") # IHT algorithm
include("BlockComIHT_inexact_diffAS_opt_oldTest_MT.jl") # IHT algorithm but active set constructed inside IHT
include("BlockInexactLS_MT.jl") # local search algorithm
include("l0_IHT_opt.jl") # individual L0 regressions to find active set

# sparse regression with IHT and local search
function BlockComIHT_inexactAS_diff(; X,
                    y,
                    rho,
                    study = nothing, # dummy variable
                    beta = 0,
                    scale = true,
                    lambda1 = 0,
                    lambda2 = 0,
                    lambda_z = 0,
                    maxIter = 5000,
                    localIter = 50,
                    maxIter_in = nothing,
                    maxIter_out = nothing,
                    eig = nothing,
                    eigenVec = nothing,
                    idx = nothing,
                    ASmultiplier = 4,
                    svdFlag = false,
                    WSmethod = 1,
                    ASpass = false
                    )

    # rho is number of non-zero coefficient
    # beta is a feasible initial solution
    # scale -- if true then scale covaraites before fitting model
    # maxIter is maximum number of iterations
    # max eigenvalue for Lipschitz constant
    # localIter is a vector as long as lambda1/lambda2 and specifies the number of local search iterations for each lambda
    # idx -- if nothing then fit individual l0 regressions to find it
    # ASmultiplier is number that we multiple rho by to get size of initial active set for first lambda in path
    # unlike other versions, WSmethod == 2 means that we use the old version that does not set warm starts before hand
    # ASpass means the active sets are passed between subsequent tuning values

    y = Matrix(y);
    X = Matrix(X);
    n, p = size(X); # number of covaraites
    beta = Matrix(beta); # initial value
    rho = Int64(rho);
    # study = Int.(study);
    K = size(y, 2); # length( unique(study) ); # number of studies
    #indxList = [Vector{Int64}() for i in 1:K]; # list of vectors of indices of studies
    #nVec = Vector{Int64}(undef, K) #nVec = zeros(K); # vector of sample sizes of studies

    if isnothing(maxIter_in)
        maxIter_in = maxIter
    end

    if isnothing(maxIter_out)
        maxIter_out = maxIter
    end

    # scale covariates
    if scale
        # scale covariates like glmnet
        sdMat = ones(p); # K x p matrix to save std of covariates of each study
        Ysd = ones(K); # K x 1 matrix to save std of Ys

        Xsd = std(X, dims=1) .* (n - 1) / n; # glmnet style MLE of sd
        sdMat = Xsd; # save std of covariates of ith study in ith row of matrix
        X .= X ./ Xsd; # standardize ith study's covariates
        #
        # for i = 1:K
        #     # indx = findall(x -> x == i, study); # indices of rows for ith study
        #     # indxList[i] = indx; # save indices
        #     # n_k = length(indx); # study k sample size
        #     # nVec[i] = n_k; # save sample size
        #
        #     # Ysd[i] = std(y[indx]) * (n_k - 1) / n_k; # glmnet style MLE of sd of y_k
        # end

        sdMat = hcat(1, sdMat); # add row of ones so standardize intercept by ones
        beta = beta .* sdMat'; # current solution β

        # lambda = lambda / mean(Ysd); # scale tuning parameter for L2 norm by average std of y_k

    # else
    #     # otherwise just make this a vector of ones for multiplication
    #     # by coefficient estimates later
    #     # sdMat = ones(p, K); # K x p matrix to save std of covariates of each study
    #
    #     for i = 1:K
    #         indxList[i] = findall(x -> x == i, study); # indices of rows for ith study
    #         indx = indxList[i];
    #         n_k = length(indx); # study k sample size
    #         nVec[i] = n_k; # save sample size
    #     end

    end

    ## intercept
    # add column of 1s for intercept
    X = hcat(ones(n), X);
    ncol = size(X)[2]; # num coefficients (including intercept)

    # Lipschitz constant
    if isnothing(eig)

        if svdFlag
            _, singVals, _ = svd( X, alg = LinearAlgebra.QRIteration() ) #
            eig = singVals[1] #svdvals( X[ indxList[i], :] )[1] #singVals[1]#svdvals( X[ indxList[i], :] )[1] #singVals[1]
        else
            eig = tsvd( X )[2][1]; # max eigenvalue of X^T X
        end

        # if not provided by user
        # for i = 1:K
        #     indx = findall(x -> x == i, study); # indices of rows for ith study
        #     a2 = tsvd(X[indx,:])[2][1]; # max eigenvalue of X^T X
        #     if (a2 > eig)
        #         eig = a2
        #     end
        # end
    else
        eig = Float64(eig)
    end

    # L = eig^2 * sqrt(K) / maximum(nVec) # L without regularization terms (updated in optimization fn below)

    # optimization
    vals = length(lambda1)
    βmat = zeros(ncol, K, vals) # store all of them -- last index is tuning value

    # number of local search iterations
    if length(localIter) < vals
        # if number of local iterations for each tuning not specified just choose first
        localIter = fill( localIter[1], vals ) # just use the first value of local search iterations for each value of lambda
    end

    ####################################################################
    # find initial active set with individual L0 regressions
    ####################################################################
    if isnothing(idx)

        rhoStar = min(rho * ASmultiplier, p); # active set set is bigger than actual rho
        # if no active set inidices provided, use individual sparse regressions to get an initial active set
        idx = [ Vector{Int64}(undef, rhoStar) for i in 1:K]; # list of vectors of indices of studies#zeros(p, K)

        for i = 1:K
            # this alters
            beta[:,i] = L0_iht_opt(X = X,
                                    y = y[:, i ],
                                    rho = rhoStar,
                                    beta = beta[:,i],
                                    L = eig^2 / n,
                                    n = n,
                                    maxIter = maxIter,
                                    lambda = lambda1[1], # use first ridge term
                                    p = p
                                    )

            idx[i] = findall(x-> x.>1e-9, abs.( beta[2:end, i] ) ) # save non-zero elements (not including intercept)
        end
    end

    ###############
    # optimization
    ###############

    for v = 1:vals

        if WSmethod == 1
            # use warm starts as previous value
            beta, idx1 = BlockComIHT_inexactAS_diff_opt_MT(X = X,
                                            y = y,
                                            rho = rho,
                                            # indxList = indxList,
                                            B = beta,
                                            K = K,
                                            #L = L,
                                            eig = eig,
                                            n = n,
                                            maxIter_in = maxIter_in,
                                            maxIter_out = maxIter_out,
                                            lambda1 = lambda1[v],
                                            lambda2 = lambda2[v],
                                            lambda_z = lambda_z[v],
                                            idx = idx,
                                            p = p
                                            );
            if ASpass
                idx = idx1;
            end

        else

            beta = BlockComIHT_inexactAS_diff_old_opt_MT(X = X,
                                            y = y,
                                            rho = rho,
                                            #indxList = indxList,
                                            B = beta,
                                            K = K,
                                            #L = L,
                                            eig = eig,
                                            n = n,
                                            maxIter_in = maxIter_in,
                                            maxIter_out = maxIter_out,
                                            lambda1 = lambda1[v],
                                            lambda2 = lambda2[v],
                                            lambda_z = lambda_z[v],
                                            #idx = idx,
                                            p = p
                                            );
        end

        ###############
        # local search
        ###############
        if localIter[v] > 0
            # run local search if positive number of local search iterations for this lambda1/lambda2 value
            beta = BlockInexactLS_MT(X = X,
                                y = y,
                                s = rho,
                                beta = beta,
                                lambda1 = lambda1[v],
                                lambda2 = lambda2[v],
                                lambda_z = lambda_z[v],
                                # indxList = indxList,
                                K = K,
                                n = n,
                                p = p,
                                maxIter = localIter[v] )
        end


        if scale
            βmat[:,:,v] = beta ./ sdMat'; # rescale by sd
        else
            βmat[:,:,v] = beta
        end
    end

    if vals == 1
        # if only one tuning value, just return a matrix
        return βmat[:,:,1];
    else
        return βmat;
    end

end
#
#  using CSV, DataFrames
# # #
# # # # # # # #
# dat = CSV.read("/Users/gabeloewinger/Desktop/Research/dat_ms", DataFrame);
# # dat = CSV.read("/Users/gabeloewinger/Desktop/Research/iht_error.csv", DataFrame);
#
# X = Matrix(dat[:,4:end]);
# y = (dat[:,2:3]);
# # # #
# # # # itrs = 4
# lambda1 = 1 #ones(itrs)
# lambda2 = 0 #ones(itrs)
# lambda_z = 0.01 #ones(itrs) * 0.01
# fit = BlockComIHT_inexactAS_diff(X = X,
#         y = y,
#         study = dat[:,1],
#                     beta =  ones(50, 2),#beta;#
#                     rho = 5,
#                     lambda1 = lambda1,
#                     maxIter = 5000,
#                     lambda2 = lambda2,
#                     lambda_z = lambda_z,
#                     localIter = [50],
#                     scale = true,
#                     idx = nothing,
#                     eig = nothing,
#                     #eigenVec = [0.1 0.1 0.1],
#                     svdFlag = false,
#                     WSmethod = 2,
#                     ASpass = false
# )

# include("objFun.jl") # local search
# #
# itr = 1
# objFun( X = X,
#         y = y,
#         study = dat[:,1],
#                     beta = fit[:,:, itr],
#                     lambda1 = lambda1[ itr ],
#                     lambda2 = lambda2[ itr ],
#                     lambda_z = 0,
#                     )
# #
# # number of non-zeros per study (not including intercept)
# size(findall(x -> x.> 1e-9, abs.(fit[2:end, :,1])))[1] / K

# X2 = randn(size(X))
# y2 = randn(size(y))
