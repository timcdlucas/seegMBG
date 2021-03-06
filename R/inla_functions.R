# functions for prediction from INLA MBG models

#' @name predictINLA
#' @rdname predictINLA
#'
#' @title Prediction from INLA MBG models
#'
#' @description Given a fitted \code{\link{inla}} object for a spatial
#'  geostatistical model, make predictions to a new dataset
#'  or \code{RasterBrick} either from the maximum \emph{a posterior} parameter
#'  set, or as samples from the predictive posterior.
#'
#'  Note that this function is only designed to work with a specific type of
#'  geostatistical model, fitted in a specific way and is likely to produce
#'  unexpected (i.e. wrong) results when used with other types of model.
#'
#'  Examples of things that aren't allowed are:
#'    \itemize{
#'      \item prediction using factor (discrete) variables.
#'       Though it should be possible to manually expand the factors into the
#'       correctly named dummy variables (see \code{inla$names.fixed} for the
#'       expected names) and predict to these. This includes the use of iid
#'       random effects, unfortunately.
#'      \item prediction using models constructed with anything other than an
#'       spde2 spatial model.
#'      \item spatial models fitted using 3D Cartesian coordinates (to be
#'       added soon).
#'      \item space-time models (to be added soon).
#'    }
#'
#' @param inla a fitted \code{\link{inla}} object with fixed effects terms
#'  and a spatial or spatio-temporal random effect model. If
#'  \code{method = "sample"} then \code{inla} must have been fitted with the
#'  argument \code{control.compute = list(config=TRUE)}.
#' @param data a dataframe giving all of the covariates for the fixed effects
#'  part of the model and the temporal term is applicable.
#' @param mesh the \code{\link{inla.mesh}} object used to construct the spatial
#'  random effect.
#' @param coords a character vector of length two giving the names of the
#'  columns in \code{data} which contain the coordinates of locations at which
#'  to make predictions.
#' @param type the type of prediction required. The default is on the scale of
#'  the linear predictors; the alternative \code{"response"} is on the scale of
#'  the response variable. Thus for a default binomial model the default
#'  predictions are of log-odds (probabilities on logit scale) and
#'  \code{type = "response"} gives the predicted probabilities.
#' @param method whether to draw \code{n} samples from the predict posterior
#'  (if \code{method = "sample"}, the default) or to make predictions at the
#'  maximum \emph{a posteriori} estimates of the model parameters (if
#'  \code{method = "MAP"}).  If \code{method = "sample"} then \code{inla} must
#'  have been fitted with the argument
#'  \code{control.compute = list(config=TRUE)}.
#' @param n if \code{method = "sample"}, the number of samples to draw from the
#'  predictive posterior.
#' @param fixed whether to include fixed effects terms in the predictor
#' @param spatial whether to include spatial terms in the predictor
#' @param fixed_subset an optional character vector giving a subset of covariates
#'  to include in the fixed effects prediction.
#' @param ncpu the number of cores to use to make predictions. If
#'  \code{ncpu = 1} then predicitons will be made sequentially, otherwise for
#'  \code{n > 1} a snowfall cluster will be initiated and predictions run in
#'  parallel.
#'
#' @export
#' @import snowfall
#'
#' @return predictINLA: a matrix with the same number of rows as \code{data} giving the
#'  predicted values at these locations
#'
predictINLA <- function(inla,
                        data,
                        mesh,
                        coords = c('Longitude', 'Latitude'),
                        type = c('link', 'response'),
                        method = c('sample', 'MAP'),
                        n = 1,
                        fixed = TRUE,
                        spatial = TRUE,
                        fixed_subset = NULL,
                        ncpu = 1) {

  # match multiple-choice arguments
  type <- match.arg(type)
  method <- match.arg(method)

  # check incoming data types
  stopifnot(inherits(inla, 'inla'))
  stopifnot(inla$model.random == 'SPDE2 model')
  stopifnot(inherits(data, 'data.frame'))
  stopifnot(all(sapply(data, class) != 'factor'))
  stopifnot(inherits(mesh, 'inla.mesh'))

  # check incoming data shapes
  stopifnot(length(coords) == 2 & all(coords %in% names(data)))
  stopifnot(all(inla$names.fixed %in% names(data)))

  # throw an error if there's a default model intercept
  # - supposedly messes with the spde stuff
  if ('(Intercept)' %in% inla$names.fixed) {
    stop('This model appears to contain an INLA intercept term. \
         These should not be used with spde models apparently.')
  }

  # only use one cpu if MAP
  if (method == 'MAP' & ncpu > 1) {
    warning('parallel prediction is not currently possible for MAP \
            estimation. Running sequentially instead.')
    ncpu <- 1
  }

  # ~~~~~~~~~~~~~~~~~~
  # get required data

  # ~~~
  # get link functions
  link <- inla$misc$linkfunctions$names

  # throw an error if there is more than one
  if (length(link) > 1) stop ('multiple link functions not yet supported')

  # otherwise, get the function
  link <- get(paste0('inla.link.', link))

  # ~~~
  # extract coordinates
  coords <- data[, coords]

  # ~~~
  # get parameters
  params <- getINLAParameters(inla = inla,
                              method = method,
                              n = n)

  # ~~~
  # loop through draws making predictions

  # set up snowfall cluster
  suppressMessages(snowfall::sfInit(cpus = ncpu, parallel = ncpu > 1))

  if (ncpu > 1) {
    message(sprintf('running predictions in parallel on %d cores', ncpu))
  }

  results_list <- snowfall::sfLapply(1:n,
                                     predictAll,
                                     params = params,
                                     mesh = mesh,
                                     coords = coords,
                                     data = data,
                                     fixed_subset = fixed_subset,
                                     spatial = spatial,
                                     fixed = fixed)

  suppressMessages(snowfall::sfStop())

  # combine the results into a matrix
  results <- do.call(cbind, results_list)

  # optionally switch to response scale
  if (type == 'response')
    results <- link(results, inverse = TRUE)

  # return results
  return (results)

}

#' @name predictRasterINLA
#' @rdname predictINLA
#'
#' @param raster a \code{Raster*} object containing the fixed effects
#'  covariates to use for prediction.
#' @param constants an optional named list giving constant values for named
#'  fixed effects in \code{inla}. E.g. for an intercept term names \code{int},
#'  do \code{constants = list(int = 1)}.
#' @param \dots arguments to be passed to \code{predictINLA}.
#'
#' @export
#'
#' @return predictRasterINLA: a \code{RasterBrick} or \code{RasterStack}
#'  (if \code{method = 'sample'}) or \code{RasterLayer} (if
#'  \code{method = 'MAP'}) giving pixel-level predictions from \code{inla}.

predictRasterINLA <- function (inla, raster, mesh, constants = list(), ...) {

  # ~~~~~~~~~~~~~
  # check incoming data

  # data types
  stopifnot(inherits(inla, 'inla'))
  stopifnot(inla$model.random == 'SPDE2 model')
  stopifnot(inherits(raster, c('RasterBrick', 'RasterStack', 'RasterLayer')))
  stopifnot(inherits(mesh, 'inla.mesh'))
  stopifnot(inherits(constants, 'list'))

  # ~~~
  # named fixed effects

  # get fixed effect provided by the user
  all_names <- c(names(raster), names(constants))

  # check none are missing
  missing <- !(inla$names.fixed %in% all_names)
  if (any(missing)) {
    stop (sprintf('The following named fixed effects are not in raster or constants %d', inla$names.fixed[missing]))
  }

  # check there are no duplicates
  if (any(duplicated(all_names))) {
    stop ('There are duplicate named fixed effects covariates between raster and constants' )
  }

  # ~~~
  # constants

  # check they're all named
  stopifnot(length(constants) == length(names(constants)))

  # check they all have length one
  len <- unlist(lapply(constants, length))
  stopifnot(all(len == 1))

  # ~~~~~~~~~~~~~
  # prepare data

  # find valid cells
  cells <- seegSDM:::notMissingIdx(raster[[1]])

  # get values at these locations
  data <- getValues(raster)[cells, ]

  # find bad pixels (with any NA values)
  bad_cells <- badRows(data)

  # remove them from the cell index and data
  cells <- cells[!bad_cells]
  data <- data[!bad_cells, ]

  # get a template RasterLayer for prediction
  template_raster <- raster[[1]]
  template_raster[] <- NA

  # remove raster to save memory
  rm(raster)

  # ~~~~~~~~~~~
  # add all data for prediction

  # convert data into a dataframe
  data <- data.frame(data)

  # get the prediction coordinates
  coords <- xyFromCell(template_raster, cells)
  colnames(coords) <- c('Longitude', 'Latitude')

  # add the constants and coordinates in
  data <- cbind(data, constants, coords)

  # ~~~~~~~~~~~
  # make the predictions!

  preds <- predictINLA(inla = inla,
                      data = data,
                      mesh = mesh,
                      coords = c('Longitude', 'Latitude'),
                      ...)

  # put these into the template raster
  pred_raster <- insertRaster(raster = template_raster,
                              new_vals = preds,
                              idx = cells)

  # return the prediction rasters
  return (pred_raster)

}

#' @name getINLAParameters
#' @rdname getINLAParameters
#'
#' @title Extracting parameters from INLA MBG models
#'
#' @description Given a fitted \code{\link{inla}} object for a spatial or
#'  spatio-temporal geostatistical model, extract model parameters
#'  either from the maximum \emph{a posterior} parameter set, or as samples
#'  from the predictive posterior.
#'
#' @param inla a fitted \code{\link{inla}} object with fixed effects terms
#'  and a spatial or spatio-temporal random effect model. If
#'  \code{method = "sample"} then \code{inla} must have been fitted with the
#'  argument \code{control.compute = list(config=TRUE)}.
#' @param method whether to draw \code{n} samples from the predict posterior
#'  (if \code{method = "sample"}, the default) or to make predictions at the
#'  maximum \emph{a posteriori} estimates of the model parameters (if
#'  \code{method = "MAP"}).  If \code{method = "sample"} then \code{inla} must
#'  have been fitted with the argument
#'  \code{control.compute = list(config=TRUE)}.
#' @param n if \code{method = "sample"}, the number of samples to draw from the
#'  predictive posterior.
#'
#' @return An object of class \code{params}, being a list with three elements:
#'  \itemize{
#'    \item params parameters
#'    \item names parameter names
#'    \item indices
#'      \itemize{
#'        \item fixed_idx index to fixed effect parameters in params and names
#'        \item spatial_idx index to spatial random effect parameters in params and names
#'        \item hyper_idx index to hyperparameters in params and names
#'      }
#'  }
#'
#'
getINLAParameters <- function (inla, method = c('sample', 'MAP'), n = 1) {

  # get the method
  method <- match.arg(method)

  if (method == 'MAP') {
    # if MAP estimate, get a single estimate of the model parameters

    # ~~~
    # hyper parameters
    hyper_names <- rownames(inla$summary.hyperpar)
    params_hyper <- inla$summary.hyperpar$mode

    # ~~~
    # fixed parameters
    fixed_names <- rownames(inla$summary.fixed)
    params_fixed <- inla$summary.fixed$mode

    # ~~~
    # spatial parameters
    spatial_names <- rownames(inla$summary.random[[1]])
    params_spatial <- inla$summary.random[[1]]$mode

    # ~~~
    # combine the parameters
    fixed_idx <- seq_along(params_fixed)
    spatial_idx <- seq_along(params_spatial) + length(params_fixed)
    hyper_idx <- seq_along(params_hyper) + length(params_fixed) + length(params_spatial)

    param_names <- c(fixed_names, spatial_names, hyper_names)
    params <- c(params_fixed, params_spatial, params_hyper)
    params <- list(params)


  } else if (method == 'sample') {

    # if samples, get multiple draws of the model parameters
    suppressWarnings(params <- INLA::inla.posterior.sample(inla,
                                                           n = n))

    # ~~~
    # hyper parameters

    # extract the hypers
    hypers <- lapply(params,
                     '[[',
                     'hyperpar')

    # keep their names
    hyper_names <- names(hypers[[1]])

    # ~~~
    # latent parameters
    params <- lapply(params,
                     '[[',
                     'latent')

    # keep parameter names
    param_names <- rownames(params[[1]])

    # find training data predictors
    predictor_idx <- grep('^Predictor.',
                          param_names)

    # remove them from parameter sets and names
    param_names <- param_names[-predictor_idx]
    params <- lapply(params,
                     '[',
                     -predictor_idx,
                     drop = FALSE)

    # find the spatial indices
    spatial_term <- names(inla$summary.random)
    stopifnot (length(spatial_term) == 1)
    spatial_prefix <- paste0('^', spatial_term, '.')
    spatial_idx <- grep(spatial_prefix,
                        param_names)

    # and the fixed indices should be those that remain
    fixed_idx <- (1:length(param_names))[-spatial_idx]

    # now tidy up the parameter names
    param_names[spatial_idx] <- gsub(spatial_prefix, '', param_names[spatial_idx])
    param_names[fixed_idx] <- gsub('.1$', '', param_names[fixed_idx])

    # convert spatial names to condensed numeric names (i.e. remove leading 0s)
    param_names[spatial_idx] <- as.character(as.numeric(param_names[spatial_idx]))

    # ~~~
    # combine them
    hyper_idx <- max(fixed_idx) + seq_along(hyper_names)
    param_names[hyper_idx] <- hyper_names
    for (i in 1:length(params)) params[[i]] <- c(params[[i]], hypers[[i]])

  } else {

    stop ('invalid method')

  }

  # return the results as a list
  ans <- list(params = params,
              names = param_names,
              indices = list(fixed = fixed_idx,
                             spatial = spatial_idx,
                             hyper = hyper_idx))

  class(ans) <- 'params'

  return (ans)

}

#' @name predictFixed
#' @rdname predictFixed
#'
#' @title Predict the Fixed Effect Parts of an INLA MBG Model
#'
#' @description For a given set of paramters and new dataset, get the
#'  component of the linear predictor corresponding to the fixed effects.
#'
#' @param params an object of class \code{params} produced by
#'  \code{\link{getINLAParameters}}.
#' @param data a dataframe with all the columns referred to in \code{params}.
#' @param draw which parameter set to use.
#' @param subset an optional character vector giving a subset of covariates
#'  to include in the prediction.
#'
#' @return a vector of the same length as the number of rows in \code{data},
#'  giving the values of the linear predictor corresponding to the records in
#'  \code{data}
predictFixed <- function (params, data, draw = 1, subset = NULL) {
  # still need to cope with factors and intercepts

  # check the draw number is valid
  stopifnot(draw %in% seq_len(length(params$params)))

  # get fixed effect parameter index
  idx <- params$indices$fixed

  # get the fixed effects parameter names
  names <- params$names[idx]

  # apply subset if needed
  if (!is.null(subset)) {

    # check they're in names
    stopifnot(all(subset %in% names))

    # find them
    subset_idx <- match(subset, names)

    # correct names and idx
    idx <- idx[subset_idx]
    names <- names[subset_idx]

  }

  # check the names are all in data
  stopifnot(all(names %in% names(data)))

  # extract the correct columns
  data <- as.matrix(data[, names])

  # copy INLA in setting NAs to 0s
  data[is.na(data)] <- 0

  # get the parameters
  par <- params$params[[draw]][idx]

  # get the result
  ans <- as.vector(data %*% par)

  # return it
  return (ans)

}


#' @name predictSpatial
#' @rdname predictSpatial
#'
#' @title Predict the Spatial Random Effect Part of an INLA MBG Model
#'
#' @description For a given set of paramters and new set of coordinates,
#'  get the component of the linear predictor corresponding to the spatial
#'  random effect, by linear interpolation.
#'
#' @param params an object of class \code{params} produced by
#'  \code{\link{getINLAParameters}}.
#' @param coords a two-column dataframe with the coordinates to evaluate the
#'  spatial random effect at.
#' @param mesh the \code{\link{inla.mesh}} object used to construct the spatial
#'  random effect.
#' @param draw which parameter set to use
#' @param time if a space-time model, the index to the discrete time variable
#'  for which spatial predictions are to be made in this round.
#' @param n_time if a space-time model, the length of the discrete time
#'  variable used in the model.
#'
#' @import INLA
#'
#' @return a vector of the same length as the number of rows in \code{coords},
#'  giving the corresponding values of the spatial linear predictor
#'
predictSpatial <- function (params, coords, mesh, draw = 1, time = NULL, n_time = NULL) {

  # check that n_time is present if time is not null
  if (!is.null(time) && is.null(n_time))

  # check the draw number is valid
  stopifnot(draw %in% seq_len(length(params$params)))

  # get hyper spatial effect parameter indices
  spatial_idx <- params$indices$spatial

  # get the parameters
  spatial_par <- params$params[[draw]][spatial_idx]

  # convert coords to matrix
  coords <- as.matrix(coords)

  # do the projection
  if (is.null(time)) {
    # if it's not temporally explicit

    # define projector to new locations
    proj <- INLA::inla.mesh.projector(mesh, coords)

    # project the spatial random field
    ans <- INLA::inla.mesh.project(proj, spatial_par)

  } else {
    # if it's for a particular year

    # build the A matrix directly for the year in question
    A <- INLA::inla.spde.make.A(mesh = mesh,
                               loc = coords,
                               group = rep(time, nrow(coords)),
                               n.group = n_time)

    # linearly project the spatial random field
    ans <- as.vector(A %*% spatial_par)

  }

  # return it
  return (ans)

}



#' @name predictAll
#' @rdname predictAll
#'
#' @title Predict the Linear Predictor of an INLA MBG Model
#'
#' @description For a given set of parameters and new dataset, get the
#'  predicted values of the linear predictor form the fixed and spatial
#'  random effects.
#'
#' @param draw which parameter set to use
#' @param params an object of class \code{params} produced by
#'  \code{\link{getINLAParameters}}.
#' @param mesh the \code{\link{inla.mesh}} object used to construct the spatial
#'  random effect.
#' @param coords a two-column dataframe with the coordinates to evaluate the
#'  spatial random effect at.
#' @param data a dataframe with all the columns referred to in \code{params}.
#' @param fixed_subset an optional character vector giving a subset of covariates
#'  to include in the fixed effects prediction.
#' @param fixed whether to include fixed effects terms in the predictor
#' @param spatial whether to include spatial terms in the predictor
#'
#' @return a vector of the same length as the number of rows in \code{coords}
#'  and \code{data}, giving the corresponding values of the spatial linear
#'  predictor (both from the fixed and reandom effects)
#'
predictAll <- function (draw,
                        params,
                        mesh,
                        coords,
                        data,
                        fixed_subset = NULL,
                        fixed = TRUE,
                        spatial = TRUE) {

  # some sanity checks
  stopifnot(inherits(params, 'params'))

  if (spatial) {
    stopifnot(inherits(mesh, 'inla.mesh'))
    stopifnot(inherits(coords, 'data.frame') & ncol(coords) == 2)
  }
  if (fixed) {
    stopifnot(inherits(data, 'data.frame'))
    stopifnot(inherits(fixed_subset, 'character') | is.null(fixed_subset))
  }
  if (fixed & spatial) {
    stopifnot(nrow(coords) == nrow(data))
  }


  # get the fixed effect predictions
  if (fixed) {
    # either true predictions
    pred_fixed <- predictFixed(params = params,
                               data = data,
                               draw = draw,
                               subset = fixed_subset)
  } else {
    # or zeroes
    pred_fixed <- rep(0, nrow(data))
  }

  # and the spatial random effect predictions
  if (spatial) {
    # either true predictions
    pred_spatial <- predictSpatial(params = params,
                                   coords = coords,
                                   mesh = mesh,
                                   draw = draw)
  } else {
    # or zeroes
    pred_spatial<- rep(0, nrow(coords))
  }

  # add them together and return
  ans <- pred_fixed + pred_spatial
  return (ans)

}
