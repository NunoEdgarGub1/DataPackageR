#' DataPackageR
#'
#' A framework to automate the processing, tidying and packaging of raw data into analysis-ready
#' data sets as R packages.
#'
#' DataPackageR will automate running of data processing code,
#' storing tidied data sets in an R pacakge, producing
#' data documentation stubs, tracking data object finger prints (md5 hash)
#' and tracking and incrementing a "DataVersion" string
#' in the DESCRIPTION file of the package when raw data or data
#' objects change.
#' Code to perform the data processing is passed to DataPacakgeR by the user.
#' The user also specifies the names of the tidy data objects to be stored,
#' documented and tracked in the final package. Raw data should be read from
#' "inst/extdata" but large raw data files can be read from sources external
#' to the package source tree.
#'
#' Configuration is controlled via the config.yml file created at the package root.
#' Its properties include a list of R and Rmd files that are to be rendered / sourced and
#' which read data and do the actual processing.
#' It also includes a list of r object names created by those files. These objects
#' are stored in the final package and accessible via the \code{data()} API.
#' The documentation for these objects is accessible via "?object-name", and md5
#' fingerprints of these objects are created and tracked.
#'
#' The Rmd and R files used to process the objects are transformed into vignettes
#' accessible in the final package so that the processing is fully documented.
#'
#' A DATADIGEST file in the package source keeps track of the data object fingerprints.
#' A DataVersion string is added to the package DESCRIPTION file and upated when these
#' objects are updated or changed on subsequent builds.
#'
#' Once the package is built and installed, the data objects created in the package are accessible via
#' the \code{data()} API, and
#' Calling \code{datapackage_skeleton()} and passing in R / Rmd file names, and r object names
#' onstructs a skeleton data package source tree and an associated \code{config.yml} file.
#'
#' Calling \code{build_package()} sets the build process in motion.
#' @examples
#' # A simple Rmd file that creates one data object
#' # named "tbl".
#' f <- tempdir()
#' f <- file.path(f,"foo.Rmd")
#' con <- file(f)
#' writeLines("```{r}\n tbl = table(sample(1:10,1000,replace=TRUE)) \n```\n",con=con)
#' close(con)
#'
#' # construct a data package skeleton named "MyDataPackage" and pass
#' # in the Rmd file name with full path, and the name of the object(s) it
#' # creates.
#'
#' pname <- basename(tempfile())
#' datapackage_skeleton(name=pname,
#'    path=tempdir(),
#'    force = TRUE,
#'    r_object_names = "tbl",
#'    code_files = f)
#'
#' # call build_package to run the "foo.Rmd" processing and
#' # build a data package.
#' package_build(file.path(tempdir(), pname))
#'
#' # "install" the data package
#' devtools::load_all(file.path(tempdir(), pname))
#'
#' # read the data version
#' data_version(pname)
#'
#' # list the data sets in the package.
#' data(package = pname)
#'
#' # The data objects are in the package source under "/data"
#' list.files(pattern="rda", path = file.path(tempdir(),pname,"data"), full = TRUE)
#'
#' # The documentation that needs to be edited is in "/R"
#' list.files(pattern="R", path = file.path(tempdir(), pname,"R"), full = TRUE)
#' readLines(list.files(pattern="R", path = file.path(tempdir(),pname,"R"), full = TRUE))
#' # view the documentation with
#' ?tbl
#' @docType package
#' @name DataPackageR-package
NULL


.validate_render_root <- function(x) {
  # catch an error if it doesn't exist
  render_root <-
    try(normalizePath(x,
      mustWork = TRUE,
      winslash = "/"
    ), silent = TRUE)
  if (inherits(render_root, "try-error")) {
    flog.error(paste0("render_root  = ", x, " doesn't exist."))
    # try creating, even if it's an old temp dir.
    # This isn't ideal. Would like to rather say it's a temporary
    # directory and use the current one..
    return(FALSE)
  }
  return(TRUE)
}


#' Process data generation code in 'data-raw'
#'
#' Assumes .R files in 'data-raw' generate rda files to be stored in 'data'.
#' Sources datasets.R which can source other R files.
#' R files sourced by datasets.R must invoke \code{sys.source('myRfile.R',env=topenv())}.
#' Meant to be called before R CMD build.
#' @name DataPackageR
#' @param arg \code{character} name of the package to build.
#' @return logical TRUE if succesful, FALSE, if not.
#' @importFrom desc desc
#' @importFrom rmarkdown render
#' @importFrom utils getSrcref modifyList
DataPackageR <- function(arg = NULL) {
  requireNamespace("futile.logger")
  requireNamespace("yaml")
  pkg_dir <- arg
  pkg_dir <- normalizePath(pkg_dir, winslash = "/")
  raw_data_dir <- "data-raw"
  target <- normalizePath(file.path(pkg_dir, raw_data_dir), winslash = "/")
  raw_data_dir <- target

  # validate that render_root exists.
  # if it's an old temp dir, what then?

  if (!file.exists(target)) {
    flog.fatal(paste0("Directory ", target, " doesn't exist."))
    {
      stop("exiting", call. = FALSE)
    }
  } else {
    logpath <-
      normalizePath(
        file.path(pkg_dir, "inst/extdata"),
        winslash = "/"
      )
    logpath <- file.path(logpath, "Logfiles")

    dir.create(logpath, recursive = TRUE, showWarnings = FALSE)
    # open a log file
    LOGFILE <- file.path(logpath, "processing.log")
    flog.appender(appender.tee(LOGFILE))
    flog.info(paste0("Logging to ", LOGFILE))
    # we know it's a proper package root, but we want to test if we have the
    # necessary subdirectories
    testme <- file.path(pkg_dir, c("R", "inst", "data", "data-raw"))
    if (!all(utils::file_test(testme, op = "-d"))) {
      flog.fatal(paste0(
        "You need a valid package data strucutre.",
        " Missing ./R ./inst ./data or",
        "./data-raw subdirectories."
      ))
      {
        stop("exiting", call. = FALSE)
      }
    }
    flog.info("Processing data")
    # read YAML
    ymlfile <- dir(
      path = pkg_dir, pattern = "^datapackager.yml$",
      full.names = TRUE
    )
    if (length(ymlfile) == 0) {
      flog.fatal(paste0("Yaml configuration file not found at ", pkg_dir))
      {
        stop("exiting", call. = FALSE)
      }
    }
    ymlconf <- read_yaml(ymlfile)
    # test that the structure of the yaml file is correct!
    if (!"configuration" %in% names(ymlconf)) {
      flog.fatal("YAML is missing 'configuration:' entry")
      {
        stop("exiting", call. = FALSE)
      }
    }
    if (!all(c("files", "objects") %in%
      purrr::map(ymlconf, names)[["configuration"]])) {
      flog.fatal("YAML is missing files: and objects: entries")
      {
        stop("exiting", call. = FALSE)
      }
    }
    flog.info("Reading yaml configuration")
    # files that have enable: TRUE
    assert_that("configuration" %in% names(ymlconf))
    assert_that("files" %in% names(ymlconf[["configuration"]]))
    assert_that(!is.null(names(ymlconf[["configuration"]][["files"]])))

    r_files <- unique(names(
      Filter(
        x = ymlconf[["configuration"]][["files"]],
        f = function(x) x$enabled
      )
    ))
    if (length(r_files) == 0) {
      flog.fatal("No files enabled for processing!")
      {
        stop("error", call. = FALSE)
      }
    }
    objects_to_keep <- purrr::map(ymlconf, "objects")[["configuration"]]
    render_root <- .get_render_root(ymlconf)
    if (!.validate_render_root(render_root)) {
      flog.fatal(paste0(
        "Can't create, or render_root = ",
        render_root, " doesn't exist"
      ))
      stop("error", call. = FALSE)
    } else {
      render_root <- normalizePath(render_root, winslash = "/")
    }

    r_files <- file.path(raw_data_dir, r_files)
    if (all(!file.exists(r_files))) {
      flog.fatal(paste0("Can't find any R or Rmd files."))
      flog.fatal(paste0(
        "     Cant' find file: ",
        r_files[!file.exists(r_files)]
      ))
      stop("error", call. = FALSE)
    }
    flog.info(paste0("Found ", r_files))
    # TODO fix hidden warnings in test cases
    old_data_digest <- .parse_data_digest(pkg_dir = pkg_dir)
    description_file <- normalizePath(file.path(pkg_dir, "DESCRIPTION"),
      winslash = "/"
    )
    pkg_description <- try(read.description(file = description_file),
      silent = TRUE
    )
    if (inherits(pkg_description, "try-error")) {
      flog.fatal("No valid DESCRIPTION file")
      {
        stop(
          paste0(
            "You need a valid package DESCRIPTION file.",
            "Please see Writing R Extensions",
            "(http://cran.r-project.org/doc/manuals/",
            "r-release/R-exts.html#The-DESCRIPTION-file).\n"
          ),
          pkg_description
        )
      }
    }
    # check that we have at least one file
    # This is caught elsewhere

    if (length(objects_to_keep) == 0) {
      flog.fatal("You must specify at least one data object.")
      {
        stop("exiting", call. = FALSE)
      }
    }
    # TODO Can we configure documentation in yaml?
    do_documentation <- FALSE
    # This flag indicates success
    can_write <- FALSE
    # environment for the data
    ENVS <- new.env(hash = TRUE, parent = .GlobalEnv)
    for (i in seq_along(r_files)) {
      dataenv <- new.env(hash = TRUE, parent = .GlobalEnv)
      # assign ENVS into dataenv.
      # provide functions in the package to read from it.
      assign(x = "ENVS", value = ENVS, dataenv)
      flog.info(paste0(
        "Processing ", i, " of ",
        length(r_files), ": ", r_files[i],
        "\n"
      ))
      # config file goes in the root render the r and rmd files
      rmarkdown::render(
        input = r_files[i], envir = dataenv,
        output_dir = logpath, clean = FALSE, knit_root_dir = render_root
      )
      # The created objects
      object_names <- ls(dataenv)
      flog.info(paste0(
        sum(objects_to_keep %in% object_names),
        " required data objects created by ",
        basename(r_files[i])
      ))
      if (sum(objects_to_keep %in% object_names) > 0) {
        for (o in objects_to_keep[objects_to_keep %in% object_names]) {
          assign(o, get(o, dataenv), ENVS)
        }
      }
    }
    # currently environments for each file are independent.
    dataenv <- ENVS
    # Digest each object
    new_data_digest <- .digest_data_env(ls(ENVS), dataenv, pkg_description)
    if (!is.null(old_data_digest)) {
      string_check <- .check_dataversion_string(
        old_data_digest,
        new_data_digest
      )
      can_write <- FALSE
      stopifnot(!((!.compare_digests(
        old_data_digest,
        new_data_digest
      )) & string_check$isgreater))
      if (.compare_digests(
        old_data_digest,
        new_data_digest
      ) &
        string_check$isequal) {
        can_write <- TRUE
        flog.info(paste0(
          "Processed data sets match ",
          "existing data sets at version ",
          new_data_digest[["DataVersion"]]
        ))
      } else if ((!.compare_digests(
        old_data_digest,
        new_data_digest
      )) &
        string_check$isequal) {
        updated_version <- .increment_data_version(
          pkg_description,
          new_data_digest
        )
        pkg_description <- updated_version$pkg_description
        new_data_digest <- updated_version$new_data_digest
        can_write <- TRUE
        flog.info(paste0(
          "Data has been updated and DataVersion ",
          "string incremented automatically to ",
          new_data_digest[["DataVersion"]]
        ))
      } else if (.compare_digests(
        old_data_digest,
        new_data_digest
      ) &
        string_check$isgreater) {
        # edge case that shouldn't happen
        # but we test for it in the test suite
        can_write <- TRUE
        flog.info(paste0(
          "Data hasn't changed but the ",
          "DataVersion has been bumped."
        ))
      } else if (string_check$isless & .compare_digests(
        old_data_digest,
        new_data_digest
      )) {
        # edge case that shouldn't happen but
        # we test for it in the test suite.
        flog.info(paste0(
          "New DataVersion is less than ",
          "old but data are unchanged"
        ))
        new_data_digest <- old_data_digest
        pkg_description[["DataVersion"]] <- new_data_digest[["DataVersion"]]
        can_write <- TRUE
      } else if (string_check$isless & !.compare_digests(
        old_data_digest,
        new_data_digest
      )) {
        updated_version <- .increment_data_version(
          pkg_description,
          new_data_digest
        )
        pkg_description <- updated_version$pkg_description
        new_data_digest <- updated_version$new_data_digest
        can_write <- TRUE
      }
      if (can_write) {
        .save_data(new_data_digest,
          pkg_description,
          ls(dataenv),
          dataenv,
          old_data_digest = old_data_digest,
          pkg_path = pkg_dir
        )
        do_documentation <- TRUE
      }
    } else {
      .save_data(new_data_digest,
        pkg_description,
        ls(dataenv),
        dataenv,
        old_data_digest = NULL,
        pkg_path = pkg_dir
      )
      do_documentation <- TRUE
    }
    if (do_documentation) {
      # Run .doc_autogen #needs to be run when we have a partial build..
      if (!file.exists(file.path(target, "documentation.R"))) {
        .doc_autogen(basename(pkg_dir),
          ds2kp = ls(dataenv),
          env = dataenv,
          path = target
        )
      }
      # parse documentation
      doc_parsed <- .doc_parse(file.path(target, "documentation.R"))
      .identify_missing_docs <- function(environment = NULL,
                                               description = NULL,
                                               docs = NULL) {
        setdiff(
          ls(environment),
          setdiff(
            names(docs),
            description[["Package"]]
          )
        )
      }
      # case where we add an object,
      # ensures we combine the documentation properly
      missing_doc_for_autodoc <- .identify_missing_docs(
        dataenv,
        pkg_description,
        doc_parsed
      )
      if (length(missing_doc_for_autodoc) != 0) {
        tmptarget <- tempdir()
        file.info("Writing missing docs.")
        .doc_autogen(basename(pkg_dir),
          ds2kp = missing_doc_for_autodoc,
          env = dataenv,
          path = tmptarget,
          name = "missing_doc.R"
        )
        missing_doc <- .doc_parse(file.path(tmptarget, "missing_doc.R"))
        doc_parsed <- .doc_merge(
          old = doc_parsed,
          new = missing_doc
        )
        file.info("Writing merged docs.")
        docfile <- file(
          file.path(
            target,
            paste0("documentation", ".R")
          ),
          open = "w"
        )
        for (i in seq_along(doc_parsed)) {
          writeLines(text = doc_parsed[[i]], con = docfile)
        }
      }
      # Partial build if enabled=FALSE for
      # any file We've disabled an object but don't
      # want to overwrite its documentation
      # or remove it The new approach just builds
      # all the docs independent of what's enabled.
      save_docs <- do.call(c, doc_parsed)
      docfile <- file(file.path(pkg_dir, "R",
        pattern = paste0(pkg_description$Package, ".R")
      ),
      open = "w"
      )
      for (i in seq_along(save_docs)) {
        writeLines(text = save_docs[[i]], con = docfile)
      }
      close(docfile)
      flog.info(
        paste0(
          "Copied documentation to ",
          file.path(pkg_dir, "R", paste0(pkg_description$Package, ".R"))
        )
      )
      # TODO test that we have documented
      # everything successfully and that all files
      # have been parsed successfully
      can_write <- TRUE
    }
    eval(expr = expression(rm(list = ls())), envir = dataenv)
    # copy html files to vignettes
    .ppfiles_mkvignettes(dir = pkg_dir)
  }
  flog.info("Done")
  return(can_write)
}


.ppfiles_mkvignettes <- function(dir = NULL) {
  usethis::proj_set(dir)
  pkg <- desc::desc(dir)
  pkg$set_dep("knitr", "Suggests")
  pkg$set_dep("rmarkdown", "Suggests")
  pkg$set("VignetteBuilder" = "knitr")
  pkg$write()
  usethis::use_directory("vignettes")
  usethis::use_directory("inst/doc")
  # TODO maybe copy only the files that have both html and Rmd.
  rmdfiles_for_vignettes <-
    list.files(
      path = file.path(dir, "data-raw"),
      pattern = "Rmd$",
      full.names = TRUE,
      recursive = FALSE
    )
  htmlfiles_for_vignettes <-
    list.files(
      path = file.path(dir, "inst/extdata/Logfiles"),
      pattern = "html$",
      full.names = TRUE,
      recursive = FALSE
    )
  purrr::map(
    htmlfiles_for_vignettes,
    function(x) {
      file.copy(x,
        file.path(
          dir,
          "inst/doc",
          basename(x)
        ),
        overwrite = TRUE
      )
    }
  )
  utils::capture.output(purrr::map(
    rmdfiles_for_vignettes,
    function(x) {
      file.copy(x,
        file.path(
          dir,
          "vignettes",
          basename(x)
        ),
        overwrite = TRUE
      )
    }
  ))
  vignettes_to_process <- list.files(
    path = file.path(dir, "vignettes"),
    pattern = "Rmd$",
    full.names = TRUE,
    recursive = FALSE
  )
  write_me_out <- purrr::map(vignettes_to_process, function(x) {
    title <- "Default Vignette Title. Add yaml title: to your document"
    thisfile <- read_file(x)
    stripped_yaml <- gsub("---\\s*\n.*\n---\\s*\n", "", thisfile)
    frontmatter <- gsub("(---\\s*\n.*\n---\\s*\n).*", "\\1", thisfile)
    con <- textConnection(frontmatter)
    fm <- rmarkdown::yaml_front_matter(con)
    if (is.null(fm[["vignette"]])) {
      # add boilerplate vignette yaml
      if (!is.null(fm$title)) {
        title <- fm$title
      }
      fm$vignette <- paste0("%\\VignetteIndexEntry{", title, "}
                           %\\VignetteEngine{knitr::rmarkdown}
                           \\usepackage[utf8]{inputenc}")
    } else {
      # otherwise leave it as is.
    }
    tmp <- fm$vignette
    tmp <- gsub(
      "  $",
      "",
      paste0(
        "vignette: >\n  ",
        gsub(
          "\\}\\s*",
          "\\}\n  ",
          tmp
        )
      )
    )
    fm$vignette <- NULL
    write_me_out <- paste0(
      "---\n",
      paste0(yaml::as.yaml(fm), tmp),
      "---\n\n",
      stripped_yaml
    )
    write_me_out
  })
  names(write_me_out) <- vignettes_to_process
  for (i in vignettes_to_process) {
    writeLines(write_me_out[[i]], con = i)
    writeLines(write_me_out[[i]],
      con = file.path(
        dir,
        "inst/doc",
        basename(i)
      )
    )
  }
}
