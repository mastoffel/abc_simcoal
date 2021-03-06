library(strataG)
library(dplyr)
library(truncnorm)

# number of simulations
num_sim <- 100

# create data.frame with all parameter values ---------------
# sample size
sample_size <- rep(50, num_sim)
# number of loci
num_loci <- rep(20, num_sim)

# simulate diploid effective pop size, bottleneck size and historical pop size
# make sure that bottleneck pop size is smaller than historical pop size and current pop size
create_N <- function(){
  nbot <- 1
  nhist <- 1
  pop_size <- 1
  while(!(nbot < pop_size) & !(nbot < nhist)){
    pop_size <- round(rtruncnorm(1, a=1, b=300000, mean = 10000, sd = 50000), 0)
    nbot <- round(runif(1, min = 1, max = 500), 0)
    nhist <- round(rtruncnorm(1, a=1, b=300000, mean = 10000, sd = 50000), 0)
  }
  c(pop_size, nbot, nhist)
}
all_N <- as.data.frame(t(replicate(num_sim, create_N())))
names(all_N) <- c("pop_size", "nbot", "nhist")

# calculate popsizes relative to current effective popsize
all_N <- mutate(all_N, nbot_prop = nbot / pop_size)
all_N <- mutate(all_N, nhist_prop = nbot / nhist)

# simulate vectors for end and start of bottleneck
# min generation time is 6 years, max is 21.6 in the Pinnipeds
# make sure that the end of the bottleneck is always later (or earlier in generations backwards)
# than the start of the bottleneck
create_t <- function(){
  tbotend <- 1
  tbotstart <- 1
  while(!(tbotend < tbotstart)){
    tbotend <- runif(1, min = 1, max = 40)
    tbotstart <- runif(1, min = 20, max = 80)
  }
  c(tbotend, tbotstart)
}
all_t <- as.data.frame(t(replicate(num_sim, create_t())))
names(all_t) <- c("tbotend", "tbotstart")

# mutation model
mut_rate <- rgamma(num_sim, 3, rate = 1000)
# parameter of the geometric distribution: decides about the proportion of multistep mutations
gsm_param <- runif(num_sim, min = 0, max = 0.3)
range_constraint <- rep(0, num_sim)

all_params <- cbind(sample_size, num_loci, all_N, all_t, mut_rate, gsm_param, range_constraint)


# function to apply over every row of the parameter dataframe, simulate microsats
# based on the coalescent with simcoal2 and compute summary statistics with strataG


run_sims <- function(param_set, model){

  pop_info <- strataG::fscPopInfo(pop.size = param_set[["pop_size"]], sample.size = param_set[["sample_size"]])
  mig_rates <- matrix(0)
  
  if (model == "bottleneck"){
    hist_ev <- strataG::fscHistEv(
      num.gen = c(param_set[["tbotend"]], param_set[["tbotstart"]]), source.deme = c(0, 0),
      sink.deme = c(0, 0), new.sink.size = c(param_set[["nbot_prop"]], param_set[["nhist_prop"]])
    )
  }
  
  if (model == "neutral"){
    hist_ev <- strataG::fscHistEv(
      num.gen = param_set[["tbotstart"]], source.deme = 0,
      sink.deme = 0, new.sink.size = param_set[["nhist_prop"]]
    )
  }
  
  msat_params <- strataG::fscLocusParams(
    locus.type = "msat", num.loci = param_set[["num_loci"]], 
    mut.rate = param_set[["mut_rate"]], gsm.param = param_set[["gsm_param"]], 
    range.constraint = param_set[["range_constraint"]], ploidy = 2
  )
  
  sim_msats <- strataG::fastsimcoal(pop.info = pop_info, locus.params = msat_params, 
                           hist.ev = hist_ev, exec = "/home/martin/bin/fsc25221")
  
  
  # calc summary statistics
  
  # num_alleles, allel_richness, prop_unique_alleles, expt_het, obs_het
  # mean and sd
  num_alleles <- strataG::numAlleles(sim_msats)
  num_alleles_mean <- mean(num_alleles, na.rm = TRUE)
  num_alleles_sd <- sd(num_alleles, na.rm = TRUE)
  # exp_het
  exp_het <- strataG::exptdHet(sim_msats)
  exp_het_mean <- mean(exp_het, na.rm = TRUE)
  exp_het_sd <- mean(exp_het, na.rm = TRUE)
  # obs_het
  obs_het <- strataG::obsvdHet(sim_msats)
  obs_het_mean <- mean(obs_het, na.rm = TRUE)
  obs_het_sd <- sd(obs_het, na.rm = TRUE)
  # mratio mean and sd
  mratio <- strataG::mRatio(sim_msats, by.strata = FALSE, rpt.size = 1)
  mratio_mean <- mean(mratio, na.rm = TRUE)
  mratio_sd <- stats::sd(mratio, na.rm = TRUE)
  # allele frequencies
  afs <- strataG::alleleFreqs(sim_msats)
  # prop low frequency alleles
  prop_low_af <- function(afs){
    # low_afs <- (afs[, "freq"] / sum(afs[, "freq"])) < 0.05
    low_afs <- afs[, "prop"] < 0.05
    prop_low <- sum(low_afs) / length(low_afs)
  }
  # and mean/sd for all
  prop_low_afs <- unlist(lapply(afs, prop_low_af))
  prop_low_afs_mean <- mean(prop_low_afs, na.rm = TRUE)
  prop_low_afs_sd <- stats::sd(prop_low_afs, na.rm = TRUE)
  # allele range
  allele_range <- unlist(lapply(afs, function(x) diff(range(as.numeric(row.names(x))))))
  mean_allele_range <- mean(allele_range, na.rm = TRUE)
  sd_allele_range <- sd(allele_range, na.rm = TRUE)
  # allele size variance
  allele_size_sd <- unlist(lapply(afs, function(x) sd(as.numeric(row.names(x)), na.rm = TRUE)))
  mean_allele_size_sd <- mean(allele_size_sd, na.rm = TRUE)
  sd_allele_size_sd <- sd(allele_size_sd, na.rm = TRUE)
  
  out <- data.frame(
    num_alleles_mean, num_alleles_sd,
    exp_het_mean, exp_het_sd,
    obs_het_mean, obs_het_sd,
    mean_allele_size_sd, sd_allele_size_sd,
    mean_allele_range, sd_allele_range,
    mratio_mean, mratio_sd,
    prop_low_afs_mean, prop_low_afs_sd
  )
}

# runs well
sims_bot <- apply(all_params, 1, run_sims, model = "bottleneck")
sims_df_bot <- as.data.frame(data.table::rbindlist(sims_bot))

sims_neut <- apply(all_params, 1, run_sims, model = "neutral")
sims_df_neut <- as.data.frame(data.table::rbindlist(sims_neut))

# gives errors
cl <- makeCluster(getOption("cl.cores", 20))
# clusterEvalQ(cl, c(library("strataG")))
sims <- parApply(cl, all_params, 1, run_sims, model = "bottleneck")
sims_df <- as.data.frame(data.table::rbindlist(sims))
stopCluster(cl)

# 
# 

# 

