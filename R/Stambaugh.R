#' Implement Stamgaugh Covariance estimate for multiple starting dates
#'
#' @details
#' This method takes in data as a matrix or an xts object where multiple
#' time series with different starting dates are merged together. It then
#' computes a covariance estimator as described in Stambugh (1997). Covariance
#' estimate can also be robustified
#'
#' @param  R xts or matrix of asset returns
#' @param  ... allows passing additional paramters
#' @importFrom facmodTS fitTsfm
#' @importFrom robustbase rrcov.control
#' @import  RCurl robustbase xts zoo
#' @author Rohit Arora
#' @export
#'
#'
stambaugh.est <- function(R, ...) {
   # Given long data and a short data, fit a time series factor model
   # to the short data with truncated long data as factors
   covariance.est <- function(rlong, rshort, loc.long, cov.long, ...) {
      long <- as.matrix(rlong)

      short <- as.matrix(rshort)
      short <- short[complete.cases(short), , drop = FALSE]

      s <- nrow(short)
      trunc.long <- tail(long, s)
      .data <- na.omit(cbind(trunc.long, short))

      add.args <- as.list(substitute(list(...)))[-1L]
      if (add.args$fit.method == "LS" &&
         "control" %in% names(add.args)) {
         add.args[["control"]] <- NULL
      }

      args <- list(
         asset.names = colnames(short),
         factor.names = colnames(trunc.long), data = .data
      )
      args <- c(args, add.args)

      fit <- do.call(fitTsfm, args)

      B <- as.matrix(fit$beta)
      resid <- do.call(cbind, lapply(fit$asset.fit, residuals))

      resid.cov <- if (robust) {
         if (ncol(resid) == 1) {
            fit$resid.sd^2
         } else {
            covMcd(resid)$cov
         }
      } else {
         cov(resid)
      }
      
      resid.cov <- as.matrix(resid.cov)

      loc.short <- as.matrix(fit$alpha) + B %*% loc.long
      loc.est <- rbind(loc.long, loc.short)

      cov.short.long <- B %*% cov.long
      cov.long.short <- t(cov.short.long)
      cov.short.short <- resid.cov + B %*% cov.long %*% t(B)

      cov.est <- cbind(
         rbind(cov.long, cov.short.long),
         rbind(cov.long.short, cov.short.short)
      )
      rownames(cov.est) <- colnames(cov.est) <- NULL

      list(loc = loc.est, cov = cov.est)
   }

   data.m <- as.matrix(R)

   # remove rows with all NA
   data.m <- data.m[rowSums(is.na(data.m)) != ncol(data.m), ,drop = FALSE]
   if (nrow(data.m) == 0) {
      return(NA)
   }

   col.names <- colnames(data.m)

   add.args <- as.list(substitute(list(...)))[-1L]
   robust <- ifelse("fit.method" %in% names(add.args),
      ifelse(add.args$fit.method == "Robust", TRUE, FALSE),
      FALSE
   )

   control <- rrcov.control()
   mcd.alpha <- control$alpha  # Default alpha from rrcov.control
   
   if (robust) {
     # Set 'method' to "covMcd" if not provided in 'add.args'
     add.args[["method"]] <- ifelse("method" %in% names(add.args), 
                                    add.args[["method"]], 
                                    "covMcd")
     
     # Update 'control' if provided in 'add.args', otherwise use default
     if ("control" %in% names(add.args)) {
       control <- add.args[["control"]]
       mcd.alpha <- control$alpha  # Update alpha if 'control' is provided
     } else {
       add.args[["control"]] <- control
     }
   }
   

   # Idea is to sort columns from maximum to minum data. Apply the long-short
   # routine and use its estimate for the next step. In the next step use the
   # the previously computed covariance estimate as estimate for long data and
   # compute a new estimate by regressing short data on long data

   # We want to optimize this procedure by grouping columns that have the same
   # length to speed by regression.

   # Get the last NA in each column
   start <- apply(data.m, 2, function(col) which.min(is.na(col)))

   # Sorting will change the order of user supplied columns so store the original
   # order that can be used on the sorted order
   ord.start <- order(start)
   old.start <- sapply(1:length(start), function(x) which(ord.start == x))

   # sort columns that have maximum data
   sort.start <- start[ord.start]
   unique.sort.start <- unique(sort.start)
   len <- length(unique.sort.start)

   # group columns that have the same length
   sort.count <- as.numeric(table(sort.start))
   cum.sort.count <- cumsum(sort.count)

   data.sort <- data.m[, ord.start, drop = FALSE]

   # start by computing the mean and covariance of longest columns that have the same len
   temp.data <- data.sort[, 1:cum.sort.count[1], drop = FALSE]

   # Determine if the data is univariate or multivariate
   is_univariate <- ncol(temp.data) == 1
   
   # Compute location and covariance estimates based on robustness and dimensionality
   if (robust) {
     if (is_univariate) {
       loc.est <- as.matrix(as.numeric(coef(lmrob(temp.data ~ 1))), nrow = 1)
       names(loc.est) <- colnames(temp.data)
       cov.est <- as.matrix(scaleTau2(temp.data)^2, nrow = 1)
     } else {
       mcd <- covMcd(temp.data, alpha = mcd.alpha)
       loc.est <- as.matrix(mcd$center, nrow = 1)
       cov.est <- as.matrix(mcd$cov)
     }
   } else {
     loc.est <- as.matrix(apply(temp.data, 2, mean), nrow = 1)
     cov.est <- as.matrix(cov(temp.data))
   }
   
   # extract a long block and a short block and let the basic routine do the job.
   # Feed its output to the next set of grouped columns

   for (j in 1:(len - 1)) {
      if (len == 1) break

      end <- cum.sort.count[j]
      long <- data.sort[, 1:end, drop = FALSE]
      start <- (1 + end)
      end <- cum.sort.count[j + 1]
      short <- data.sort[, start:end, drop = FALSE]

      est <- covariance.est(long, short, loc.est, cov.est, add.args)
      loc.est <- est$loc
      cov.est <- est$cov
   }

   # lets re-arrange back to return in the user-supplied order
   loc.est <- loc.est[old.start, , drop = FALSE]
   rownames(loc.est) <- col.names

   cov.est <- cov.est[old.start, old.start, drop=FALSE]
   colnames(cov.est) <- col.names
   rownames(cov.est) <- col.names

   list(
      data = data.m, loc = loc.est, cov = cov.est,
      robust.params = list(control = control)
   )
}

#' Estimate covariance matrices using Stambaugh method for classical and Robust
#' methods
#'
#' @details
#' This method takes in data as a matrix or an xts object where multiple
#' time series with different starting dates are merged together. It then
#' computes a covariance estimator based on the specifed style
#'
#' @param  R xts or matrix of asset returns
#' @param  ... pass paramters to fitTimeSeriesFactorModel(facmodTS),
#' covRob, lmrob (robustbase) functions
#' @param method type of model to fit. Takes 3 values classic/robust/truncated
#' @author Rohit Arora
#' @export
#'
#'
stambaugh.fit <- function(R, method = c("classic", "robust", "truncated"), ...) {
   if (is.null(nrow(R)) || is.null(ncol(R))) stop("Invalid data")
   if (length(method) > 2) stop("Can fit atmost 2 models")
   if (!all(method %in% c("classic", "robust", "truncated"))) stop("Invalid model")

   model.classic <- model.robust <- NULL
   .data <- NULL

   add.args <- list(...)
   if ("fit.method" %in% names(add.args)) add.args["fit.method"] <- NULL

   if ("classic" %in% method) {
      args <- list(R = R, fit.method = "LS")
      args <- c(args, add.args)
      classic <- do.call(stambaugh.est, args)
      .data <- classic$data
      .Classical <- list(
         center = classic$loc, cov = classic$cov,
         dist = classic$dist, corr = FALSE, type = "Classical"
      )
      model.classic <- list(Stambaugh = .Classical)
   }

   if ("robust" %in% method) {
      args <- list(R = R, fit.method = "Robust")
      args <- c(args, add.args)
      robust <- do.call(stambaugh.est, args)
      .data <- robust$data
      .Robust <- list(
         center = robust$loc, cov = robust$cov,
         dist = robust$dist, corr = FALSE,
         robust.params = robust$robust.params, type = "Robust"
      )
      model.robust <- list("Robust Stambaugh" = .Robust)
   }

   if ("truncated" %in% method) {
      args <- list(R = na.omit(R), fit.method = "LS")
      args <- c(args, add.args)
      trunc <- do.call(stambaugh.est, args)
      .data <- trunc$data
      .Trunc <- list(
         center = trunc$loc, cov = trunc$cov,
         dist = trunc$dist, corr = FALSE, type = "Classical"
      )
      model.trunc <- list(Truncated = .Trunc)
   }

   model.list <- if (all(method %in% c("classic", "robust"))) {
      c(model.classic, model.robust)
   } else if (all(method %in% c("classic", "truncated"))) {
      c(model.classic, model.trunc)
   } else if (all(method %in% c("robust", "truncated"))) {
      c(model.robust, model.trunc)
   } else if (method == "classic") {
      model.classic
   } else if (method == "robust") {
      model.robust
   } else if (method == "truncated") model.trunc

   model.list <- list(models = model.list, data = .data)

   class(model.list) <- "stambaugh"
   model.list
}

#' Plot Ellipsis for the Stambaugh estimator
#'
#' @details
#' This method takes in fitted models for Stamgaugh Estimator. It then plots a
#' comparison of the fitted models using ellipsis plot
#'
#' @param  models fitted models for covariance
#' @importFrom fit.models ellipsesPlot.covfm
#' @export
#' @author Rohit Arora
#'
#'
stambaugh.ellipse.plot <- function(models) {
   if (length(models) != 2) stop("2 models needed for ellipse plot")

   .models <- models$models
   ellipsesPlot.covfm(.models, which.plots = 4)
}

#' An internal function that is used to calculate the Mahalanobis distance
#'
#' @details
#' The function takes in the model, data and the significance level and calculated
#' the critical values and the Mahalanobis distance.
#'
#' @param  data data used to fit the covariance
#' @param confidence level for the test
#' @param  model fitted models for covariance
#' @param  id.n number of outliers to show
#' @author Rohit Arora
#'
#' @noRd
.stambaugh.dist <- function(data, model, level, id.n = 10) {
   start <- apply(data, 2, function(col) which.min(is.na(col)))
   freq.tab <- data.frame(table(start))
   freq.tab$start <- as.numeric(levels(freq.tab$start))
   x.thresh <- c(freq.tab$start - 1, nrow(data))

   cum.sort.count <- cumsum(freq.tab$Freq)
   levels <- sapply(1:nrow(freq.tab), function(j) {
      sqrt(qchisq(1 - level, df = cum.sort.count[j], lower.tail = FALSE))
   })
   y.thresh <- levels

   outlier <- dist <- matrix(NA, nrow = nrow(data), ncol = 1)
   rownames(outlier) <- rownames(dist) <- rownames(data)

   for (i in 1:(length(x.thresh) - 1)) {
      new.start <- freq.tab$start[i]
      new.end <- ifelse(i != length(freq.tab$start),
         freq.tab$start[i + 1] - 1, nrow(data)
      )
      symdata <- coredata(data[, which(start <= new.start), drop = FALSE])

      if (model$type == "Classical") {
         fit <- stambaugh.fit(symdata, method = "classic")
         symdata <- data[new.start:new.end, which(start <= new.start), drop = FALSE]
         dist[new.start:new.end] <- sqrt(mahalanobis(
            x = symdata,
            center = fit$models$Stambaugh$center,
            cov = fit$models$Stambaugh$cov
         ))
         new.start <- x.thresh[i] + 1
         new.end <- x.thresh[i + 1]
         out <- new.start - 1 + which(dist[new.start:new.end] > y.thresh[i])
      } else if (model$type == "Robust") {
         control <- model$robust.params$control
         fit <- stambaugh.fit(symdata, method = "robust", control = control)
         symdata <- data[new.start:new.end, which(start <= new.start), drop = FALSE]
         dist[new.start:new.end] <- sqrt(mahalanobis(
            x = symdata,
            center = fit$models$`Robust Stambaugh`$center,
            cov = fit$models$`Robust Stambaugh`$cov
         ))
         
         cval <- y.thresh[i]
         out <- new.start - 1 + which(dist[new.start:new.end] > cval)
      }

      temp.n <- ifelse(length(out) > id.n, id.n, length(out))
      out <- out[order(dist[out], decreasing = TRUE)][1:temp.n]
      outlier[out] <- out
   }

   y.thresh <- c(y.thresh, tail(y.thresh, 1))
   list(dist = dist, outlier = outlier, x.thresh = x.thresh, y.thresh = y.thresh)
}

#' Compute Mahalanobis distances for each of the data points and plot it against
#' upper 2.5\% chi-square quantile
#'
#' @details
#' This method takes in fitted models for Stamgaugh Estimator. It then uses the
#' distances computed for each stage and plots it against the upper level\%
#' Chi-Square quantile
#'
#' @param  model fitted models for covariance
#' @param  level value between 0 and 1 giving the chi-squared percent point
#' used to compute threshold for juding a point as an outlier
#' @import ggplot2
#' @author Rohit Arora
#' @export
#'
#'
stambaugh.distance.plot <- function(model, level = 0.975) {
   data <- model$data
   if (ncol(data) == 0) stop("Empty Data")

   models <- model$models
   n.models <- length(models)
   if (n.models == 0) stop("Empty Models")

   if ("Truncated" %in% names(models)) stop("Truncated data not allowed")
   x.thresh <- y.thresh.classical <- y.thresh.robust <- c()

   df <- do.call(rbind, lapply(
      models,
      function(model, id.n = 10) {
         temp <- .stambaugh.dist(data, model, level, id.n)
         x.thresh <<- temp$x.thresh

         if (model$type == "Classical") {
            y.thresh.classical <<- temp$y.thresh
         } else if (model$type == "Robust") y.thresh.robust <<- temp$y.thresh

         data.frame(Type = model$type, cbind(temp$dist, temp$outlier))
      }
   ))

   dates <- try(as.Date(gsub("[A-Za-z ]+\\.", "", rownames(df))))
   df[, "Date"] <- c(seq(1:nrow(data)), seq(1:nrow(data)))
   dateCheckFailed <- ifelse(class(dates) != "try-error" &&
      all(!is.na(dates)), FALSE, TRUE)

   colnames(df) <- c("Type", "Distance", "Outlier", "Date")
   rownames(df) <- NULL
   
   my_labeller <- function(labels) {
     # Convert the list of labels to character
     labels <- lapply(labels, as.character)
     
     # Loop through each label
     for (i in seq_along(labels)) {
       if (labels[[i]] == "Classical") {
         labels[[i]] <- "Stambaugh"
       } else if (labels[[i]] == "Robust") {
         labels[[i]] <- "Robust Stambaugh"
       }
     }
     
     # Return the modified list of labels
     return(labels)
   }
   

   p <- ggplot(data = df, aes(x = !!sym("Date"), y = !!sym("Distance"))) +
     geom_point(aes(color = !!sym("Type"), shape = !!sym("Type")))  +
     facet_grid(~Type, labeller = as_labeller(my_labeller)) +
     geom_text(aes(label = ifelse(!is.na(Outlier), as.character(Outlier), ""), 
                   hjust = 1, vjust = 1)) +
      xlab("Date") +
      ylab("Square Root of Mahalanobis Distance") +
      theme(
         strip.text.x = element_text(size = 16),
         axis.text = element_text(size = 12),
         axis.title = element_text(size = 14)
      )

   for (i in 1:(length(x.thresh) - 1)) {
      data.segm <- data.frame(
         x = rep(x.thresh[i], 2),
         y = c(y.thresh.classical[i], y.thresh.robust[i]),
         xend = rep(x.thresh[i + 1], 2),
         yend = c(y.thresh.classical[i], y.thresh.robust[i]),
         Type = c("Classical", "Robust")
      )

      p <- p + geom_segment(
        data = data.segm,
        aes(x = !!sym("x"), y = !!sym("y"), xend = !!sym("xend"), yend = !!sym("yend")),
        inherit.aes = FALSE, 
        linetype = "dashed", 
        colour = "blue"
      )
      

      data.segm <- data.frame(
         x = rep(x.thresh[i + 1], 2),
         y = c(y.thresh.classical[i], y.thresh.robust[i]),
         xend = rep(x.thresh[i + 1], 2),
         yend = c(y.thresh.classical[i + 1], y.thresh.robust[i + 1]),
         Type = c("Classical", "Robust")
      )


      p <- p + geom_segment(
        data = data.segm,
        aes(x = x, y = y, xend = xend, yend = yend),
        inherit.aes = FALSE, 
        linetype = "dashed", 
        colour = "blue"
      )
      
   }

   ind <- head(floor(seq(1, nrow(data), length.out = 5)), -1)
   if (!dateCheckFailed) p <- p + scale_x_continuous(breaks = ind, labels = format(dates[ind], "%Y"))
   p <- p + theme(legend.position = "none")

   options(warn = -1)
   print(p)
   options(warn = 0)
   p
}

#' Plot Ellipsis or Distance plot for the Stambaugh estimator
#'
#' @details
#' This method takes in fitted models and a paramter for deciding the type of plot
#'
#' @param  x fitted models for covariance
#' @param  y takes values 1/2. 1 = Ellipse plot, 2 = distance plot
#' @param  ... allows passing additional paramters
#'
#' @method plot stambaugh
#' @author Rohit Arora
#' @export
#'
plot.stambaugh <- function(x, y = c(1, 2), ...) {
   n <- length(x$models)
   if (n != 2 && y[1] == 1) stop("2 models needed for ellipse plot")

   which <- y[1]

   if (!which %in% c(1, 2)) stop("Unknown plot selected")

   if (which == 1) stambaugh.ellipse.plot(x)
   if (which == 2) stambaugh.distance.plot(x, ...)
}

#' Plot data to visualize missing values
#'
#' @details
#' This method takes in data as an xts object and plots the data.
#' Missing values highlighted in red for matrix plot and time series of returns
#' are shown in in Summary plot
#'
#' @param  data an xts/zoo object
#' @param  which takes values 3/4. 3 = Time series plot, 4 = Matrix plot
#' @import VIM reshape2
#' @author Rohit Arora
#' @export
#'
#'
plotmissing <- function(data) {
   cols <- colnames(data)
   if (length(cols) == 0) stop("Data should have column names")

   dates <- index(data[, which.min(colSums(is.na(data)))])
   
   d <- melt(coredata(data))
   colnames(d) <- c("Index", "Symbol", "Returns")
   symCount <- ncol(data)
   
   year.dates <- format(dates, "%Y")
   ind <- sapply(unique(year.dates), function(val) {
     which.max(year.dates == val)
   })
   ind.ind <- seq.int(1, length(ind), length.out = min(15, length(ind)))
   ind <- ind[ind.ind]
   
   p <- ggplot(data = d, aes(x = Index, y = Returns, colour = Symbol, group = Symbol)) +
     geom_line() +
     xlab("Dates") +
     ylab("Returns") +
     scale_x_continuous(breaks = ind, labels = year.dates[ind]) +
     facet_wrap(~Symbol, ncol = round(sqrt(symCount)), scales = "free_x") +
     theme(legend.position = "none")
   
   print(p)
}