#!/usr/bin/env perl
# EPN, Mon Aug 10 10:39:33 2015 [development began on dnaorg_annotate_genomes.pl]
# EPN, Mon Feb  1 15:07:43 2016 [dnaorg_build.pl split off from dnaorg_annotate_genomes.pl]
#
use strict;
use warnings;
use Getopt::Long;
use Time::HiRes qw(gettimeofday);
use Bio::Easel::MSA;
use Bio::Easel::SqFile;

require "dnaorg.pm"; 

#######################################################################################
# What this script does: 
#
# Preliminaries: 
#   - process options
#   - create the output directory
#   - output program banner and open output files
#   - parse the optional input files, if necessary
#   - make sure the required executables are executable
#
# Step 1. Gather and process information on reference genome using Edirect
#
# Step 2. Fetch and process the reference genome sequence
#
# Step 3. Build and calibrate models
#######################################################################################

# hard-coded-paths:
my $inf_exec_dir   = "/usr/local/infernal/1.1.1/bin/";
my $esl_fetch_cds  = "/panfs/pan1/dnaorg/programs/esl-fetch-cds.pl";

# The definition of $usage explains the script and usage:
my $usage = "\ndnaorg_build.pl <reference accession>\n";
$usage .= "\n"; 
$usage .= " FIXME: This script annotates genomes from the same species based\n";
$usage .= " on reference annotation. The reference accession is the\n";
$usage .= " first accession listed in <list file with all accessions>\n";
$usage .= "\n";
$usage .= " BASIC/COMMON OPTIONS:\n";
$usage .= "  -c           : genome is circular\n";
$usage .= "  -d <s>       : define output directory as <s>, not <reference accession>\n";
$usage .= "  -f           : force; if dir <reference accession> exists, overwrite it\n";
$usage .= "  -v           : be verbose; output commands to stdout as they're run\n";
$usage .= "  -matpept <f> : read mat_peptide info in addition to CDS info, file <f> explains CDS:mat_peptide relationships\n";
$usage .= "  -nomatpept   : ignore mat_peptide information for <reference accession> (do not model it)\n";
$usage .= "  -dirty       : do not remove intermediate files, leave them all on disk\n";
$usage .= "\n OPTIONS SPECIFIC TO INFERNAL:\n";
$usage .= "  -cslow  : use default cmcalibrate parameters, not parameters optimized for speed\n";
$usage .= "  -clocal : run cmcalibrate locally, do not submit calibration jobs for each CM to the compute farm\n";
$usage .= "\n";

my $total_seconds = -1 * secondsSinceEpoch(); # by multiplying by -1, we can just add another secondsSinceEpoch call at end to get total time
my $executable    = $0;

################# 
# process options
#################
# basic/common options:
my $dir            = undef; # set to a value <s> with -d <s>
my $do_circular    = 0;     # set to '1' with -c, genome is circular and features can span stop..start boundary
my $do_force       = 0;     # set to '1' with -f, overwrite output dir if it exists
my $be_verbose     = 0;     # set to '1' with -v, output commands as they're run
my $do_matpept     = 0;     # set to '1' if -matpept    enabled, genome has a single polyprotein, use mat_peptide info, not CDS
my $do_nomatpept   = 0;     # set to '1' if -nomatpept  enabled, we will ignore mat_peptide information if it exists for the reference
my $matpept_infile = undef; # defined if -matpept   enabled, the input file that describes relationship between CDS and mat_peptides
my $do_dirty       = 0;     # set to '1' if -dirty enabled, we will leave intermediate files that are normally removed
my $do_cslow       = 0; # set to '1' if -cslow   enabled, use default, slow, cmcalibrate parameters instead of speed optimized ones
my $do_clocal      = 0; # set to '1' if -clocal  enabled, do not submit cmcalibrate job to farm

&GetOptions("d=s"         => \$dir,
            "c"           => \$do_circular,
            "f"           => \$do_force, 
            "v"           => \$be_verbose,
            "matpept=s"   => \$matpept_infile,
            "dirty"       => \$do_dirty,
            "cslow"       => \$do_cslow, 
            "clocal"      => \$do_clocal) ||
    die "Unknown option";

if(scalar(@ARGV) != 1) { die $usage; }
my ($ref_accn) = (@ARGV);

# store options used, so we can output them 
my $opts_used_short = "";
my $opts_used_long  = "";
if(defined $dir) { 
  $opts_used_short .= "-d $dir ";
  $opts_used_long  .= "# option:  output directory specified as $dir [-d]\n"; 
}
if(defined $do_circular) { 
  $opts_used_short .= "-c ";
  $opts_used_long  .= "# option:  genome is circular, so features can span stop..start [-c]\n"; 
}
if($do_force) { 
  $opts_used_short .= "-f ";
  $opts_used_long  .= sprintf("# option:  forcing overwrite of %s directory [-f]\n", (defined $dir ? $dir : $ref_accn)); 
}
if(defined $matpept_infile) { 
  $do_matpept = 1;
  $opts_used_short .= "-matpept $matpept_infile";
  $opts_used_long  .= "# option:  using mat_peptide info, CDS:mat_peptide relationships explained in $matpept_infile [-matpept]\n";
}
if($do_dirty) { 
  $do_matpept = 1;
  $opts_used_short .= "-dirty ";
  $opts_used_long  .= "# option:  do not remove intermediate files, leave them all on disk";
}
if($do_cslow) { 
  $opts_used_short .= "-cslow ";
  $opts_used_long  .= "# option:  run cmcalibrate in default (slow) mode [-cslow]\n";
}
if($do_clocal) { 
  $opts_used_short .= "-clocal ";
  $opts_used_long  .= "# option:  running calibration jobs locally instead of on the farm [-clocal]\n";
}

#############################
# create the output directory
#############################
my $cmd;              # a command to run with runCommand()
my @early_cmd_A = (); # array of commands we run before our log file is opened
# check if the $dir exists, and that it contains the files we need
# check if our output dir $symbol exists
if(! defined $dir) { 
  $dir = $ref_accn;
}
else { 
  if($dir !~ m/\/$/) { $dir =~ s/\/$//; } # remove final '/' if it exists
}
if(-d $dir) { 
  $cmd = "rm -rf $dir";
  if($do_force) { runCommand($cmd, $be_verbose, undef); push(@early_cmd_A, $cmd); }
  else          { die "ERROR directory named $dir already exists. Remove it, or use -f to overwrite it."; }
}
if(-e $dir) { 
  $cmd = "rm $dir";
  if($do_force) { runCommand($cmd, $be_verbose, undef); push(@early_cmd_A, $cmd); }
  else          { die "ERROR a file named $dir already exists. Remove it, or use -f to overwrite it."; }
}

# create the dir
$cmd = "mkdir $dir";
runCommand($cmd, $be_verbose, undef);
push(@early_cmd_A, $cmd);

my $dir_tail = $dir;
$dir_tail =~ s/^.+\///; # remove all but last dir
my $out_root = $dir . "/" . $dir_tail . ".dnaorg_build";

#############################################
# output program banner and open output files
#############################################
my $synopsis = "dnaorg_build.pl :: build homology models for features of a reference sequence";
my $command  = "$executable $opts_used_short $ref_accn";
my $date     = scalar localtime();
outputBanner(*STDOUT, $synopsis, $command, $date, $opts_used_long);

# open the log and command files:
# set output file names and file handles, and open those file handles
my %ofile_name_H          = (); # full name for (full path to) output files
my %ofile_sname_H         = (); # short name for (no dir path) output files
my %ofile_FH_H            = (); # file handle for output files, keys are in @ofile_keys_A
my @ofile_keys_A          = ("log", "cmd"); 
my %ofile_desc_H          = (); # description of each output file
$ofile_desc_H{"log"}      = "Output printed to screen";
$ofile_desc_H{"cmd"}      = "List of executed commands";

foreach my $key (@ofile_keys_A) { 
  $ofile_name_H{$key}  = $out_root . "." . $key;
  $ofile_sname_H{$key} = $dir_tail . ".dnaorg_build." . $key; # short name (lacks directory)
  if(! open($ofile_FH_H{$key}, ">", $ofile_name_H{$key})) { 
    printf STDERR ("ERROR, unable to open $ofile_name_H{$key} for writing.\n"); 
    exit(1);
  }
}
my $log_FH = $ofile_FH_H{"log"};
my $cmd_FH = $ofile_FH_H{"cmd"};
# output files are all open, if we exit after this point, we'll need
# to close these first.

# now we have the log file open, output the banner there too
outputBanner($log_FH, $synopsis, $command, $date, $opts_used_long);

# output any commands we already executed to $log_FH
foreach $cmd (@early_cmd_A) { 
  print $cmd_FH $cmd . "\n";
}

########################################
# parse the optional input files, if nec
########################################
# -matpept <f>
my @cds2pmatpept_AA = (); # 1st dim: cds index (-1, off-by-one), 2nd dim: value array of primary matpept indices that comprise this CDS
my @cds2amatpept_AA = (); # 1st dim: cds index (-1, off-by-one), 2nd dim: value array of all     matpept indices that comprise this CDS
if(defined $matpept_infile) { 
  parseMatPeptSpecFile($matpept_infile, \@cds2pmatpept_AA, \@cds2amatpept_AA, \%ofile_FH_H);
}

###################################################
# make sure the required executables are executable
###################################################
my %execs_H = (); # hash with paths to all required executables
$execs_H{"cmbuild"}       = $inf_exec_dir . "cmbuild";
$execs_H{"cmcalibrate"}   = $inf_exec_dir . "cmcalibrate";
$execs_H{"cmfetch"}       = $inf_exec_dir . "cmfetch";
$execs_H{"cmpress"}       = $inf_exec_dir . "cmpress";
$execs_H{"esl_fetch_cds"} = $esl_fetch_cds;
validateExecutableHash(\%execs_H, \%ofile_FH_H);

###########################################################################
# Step 1. Gather and process information on reference genome using Edirect.
###########################################################################
my $progress_w = 60; # the width of the left hand column in our progress output, hard-coded
my $start_secs = outputProgressPrior("Gathering information on reference using edirect", $progress_w, $log_FH, *STDOUT);
my %cds_tbl_HHA = ();   # CDS data from .cds.tbl file, hash of hashes of arrays, 
                        # 1D: key: accession
                        # 2D: key: column name in gene ftable file
                        # 3D: per-row values for each column
my %mp_tbl_HHA = ();    # mat_peptide data from .matpept.tbl file, hash of hashes of arrays, 
                        # 1D: key: accession
                        # 2D: key: column name in gene ftable file
                        # 3D: per-row values for each column

# 1) create the edirect .mat_peptide file, if necessary
# 2) create the edirect .ftable file
# 3) create the length file
# 
# We create the .mat_peptide file first because we will die with an
# error if mature peptide info exists and neither -matpept nor
# -nomatpept was used (and we want to die as early as possible in the
# script to save the user's time)
#
# 1) create the edirect .mat_peptide file, if necessary
my $mp_file = $out_root . ".mat_peptide";

#      if -nomatpept was   enabled we don't attempt to create a matpept file
# else if -matpept was     enabled we validate that the resulting matpept file is not empty
# else if -matpept was not enabled we validate that the resulting matpept file is     empty
if(! $do_nomatpept) { 
  $cmd = "esearch -db nuccore -query $ref_accn | efetch -format gpc | xtract -insd mat_peptide INSDFeature_location product > $mp_file";
  runCommand($cmd, $be_verbose, \%ofile_FH_H);
  
  if($do_matpept) { 
    if(! -s  $mp_file) { 
      DNAORG_FAIL("ERROR, -matpept enabled but no mature peptide information exists.", 1, \%ofile_FH_H); 
    }
    addClosedOutputFile(\@ofile_keys_A, \%ofile_name_H, \%ofile_sname_H, \%ofile_desc_H, "mp", $mp_file, "Mature peptide information obtained via edirect", \%ofile_FH_H);
  }
  else { # ! $do_matpept
    if(-s $mp_file) { 
      DNAORG_FAIL("ERROR, -matpept not enabled but mature peptide information exists, use -nomatpept to ignore it.", 1, \%ofile_FH_H); 
    }
    else { 
      # remove the empty file we just created
      runCommand("rm $mp_file", $be_verbose, \%ofile_FH_H);
    }
  }
}

# 2) create the edirect .ftable file
# create the edirect ftable file
my $ft_file  = $out_root . ".ftable";
$cmd = "esearch -db nuccore -query $ref_accn | efetch -format ft > $ft_file";
runCommand($cmd, $be_verbose, \%ofile_FH_H);
addClosedOutputFile(\@ofile_keys_A, \%ofile_name_H, \%ofile_sname_H, \%ofile_desc_H, "ft", $ft_file, "Feature table obtained via edirect", \%ofile_FH_H);

# 3) create the length file
# create a file with total lengths of each accession
my $len_file  = $out_root . ".length";
my $len_file_created = $len_file . ".created";
my $len_file_lost    = $len_file . ".lost";
$cmd = "esearch -db nuccore -query $ref_accn | efetch -format gpc | xtract -insd INSDSeq_length | grep . | sort > $len_file";
runCommand($cmd, $be_verbose, \%ofile_FH_H);
addClosedOutputFile(\@ofile_keys_A, \%ofile_name_H, \%ofile_sname_H, \%ofile_desc_H, "len", $len_file, "Sequence length file", \%ofile_FH_H);
if(! -s $len_file) { 
  DNAORG_FAIL("ERROR, no length information obtained using edirect.", 1, \%ofile_FH_H); 
}  

# parse the edirect output data files that we just created
# first, parse the length file
my %totlen_H = (); # key: accession, value: total length of the sequence for that accession
parseLengthFile($len_file, \%totlen_H, \%ofile_FH_H);
if(! exists $totlen_H{$ref_accn}) { 
  DNAORG_FAIL("ERROR, problem fetching length of reference accession $ref_accn", 1, \%ofile_FH_H); 
}
my $ref_totlen = $totlen_H{$ref_accn}; # total length of reference sequence

edirectFtableOrMatPept2SingleFeatureTableInfo($ft_file, 0, "CDS", \%cds_tbl_HHA, \%ofile_FH_H); # 0: it's not a mat_peptide file
if(! exists ($cds_tbl_HHA{$ref_accn})) { 
  DNAORG_FAIL("ERROR no CDS information stored for reference accession", 1, \%ofile_FH_H); 
}
if($do_matpept) {  
  edirectFtableOrMatPept2SingleFeatureTableInfo($mp_file, 1, "mat_peptide", \%mp_tbl_HHA, \%ofile_FH_H); # 1: it is a mat_peptide file
  if (! exists ($mp_tbl_HHA{$ref_accn})) { 
    DNAORG_FAIL("ERROR -matpept enabled, but no mature peptide information stored for reference accession", 1, \%ofile_FH_H); 
  }
  # validate the CDS:mat_peptide relationships that we read from $matpept_infile
  matpeptValidateCdsRelationships(\@cds2pmatpept_AA, \%{$cds_tbl_HHA{$ref_accn}}, \%{$mp_tbl_HHA{$ref_accn}}, $do_circular, $totlen_H{$ref_accn}, \%ofile_FH_H);
}
outputProgressComplete($start_secs, undef, $log_FH, *STDOUT);

#########################################################
# Step 2. Fetch and process the reference genome sequence
##########################################################
$start_secs = outputProgressPrior("Fetching and processing the reference genome", $progress_w, $log_FH, *STDOUT);
my $fetch_file = $out_root . ".ref.fg.idfetch.in";
my $fasta_file = $out_root . ".ref.fg.fa";
my @accn_A     = ($ref_accn); # array of accessions 
my @seq_accn_A = ();      # array of actual sequence names in $fasta_file that we'll create, filled in fetchSequencesUsingEslFetchCds

# fetch the reference genome
fetchSequencesUsingEslFetchCds($execs_H{"esl_fetch_cds"}, 0, $fetch_file, $fasta_file, $do_circular, \@accn_A, \%totlen_H, \@seq_accn_A, undef, undef, \%ofile_FH_H);
addClosedOutputFile(\@ofile_keys_A, \%ofile_name_H, \%ofile_sname_H, \%ofile_desc_H, "fetch", $fetch_file, "Input file for esl-fetch-cds.pl", \%ofile_FH_H);
addClosedOutputFile(\@ofile_keys_A, \%ofile_name_H, \%ofile_sname_H, \%ofile_desc_H, "fasta", $fasta_file, "Sequence file with reference genome", \%ofile_FH_H);

my %ftr_info_HA = (); # hash of arrays, values are arrays [0..$nftr-1], 
                      # see dnaorg.pm::validateFeatureInfoHashIsComplete() for list of all keys
my $nftr;             # number of features
my $nmp;              # number of mature peptide features

# determine reference information for each feature (strand, length, coordinates, product)
getReferenceFeatureInfo(\%cds_tbl_HHA, ($do_matpept ? \%mp_tbl_HHA : undef), \%ftr_info_HA, $ref_accn, \%ofile_FH_H);
my @reqd_keys_A = ("ref_strand", "ref_len", "ref_coords", "out_product");
$nftr = validateAndGetSizeOfInfoHashOfArrays(\%ftr_info_HA, undef, \%ofile_FH_H);
$nmp  = ($do_matpept) ? scalar(@{$mp_tbl_HHA{$ref_accn}{"coords"}}) : 0;

# determine type of each feature 
determineFeatureTypes($nmp, ((@cds2pmatpept_AA) ? \@cds2pmatpept_AA : undef), \%ftr_info_HA, \%ofile_FH_H);

# fetch the reference feature sequences and populate information on the models and features
my $all_stk_file = $out_root . ".ref.all.stk";
my %mdl_info_HA = (); # hash of arrays, hash keys: "ftr_idx",  "is_first",  "is_final",  values are arrays [0..$nmdl-1];
my $sqfile = Bio::Easel::SqFile->new({ fileLocation => $fasta_file });
addClosedOutputFile(\@ofile_keys_A, \%ofile_name_H, \%ofile_sname_H, \%ofile_desc_H, "index", $fasta_file.".ssi", "Index for reference genome sequence file", \%ofile_FH_H);

fetchReferenceFeatureSequences($sqfile, $seq_accn_A[0], $ref_totlen, $out_root, $do_circular, $do_dirty, \%mdl_info_HA, \%ftr_info_HA, $all_stk_file, \%ofile_FH_H); # 0 is 'do_circular' which is irrelevant in this context
addClosedOutputFile(\@ofile_keys_A, \%ofile_name_H, \%ofile_sname_H, \%ofile_desc_H, "refstk", $all_stk_file, "Stockholm alignment file with reference features", \%ofile_FH_H);

outputProgressComplete($start_secs, undef, $log_FH, *STDOUT);

# verify our model and feature info hashes are complete
validateFeatureInfoHashIsComplete(\%ftr_info_HA, undef, \%ofile_FH_H);
my $nmdl = validateModelInfoHashIsComplete  (\%mdl_info_HA, undef, \%ofile_FH_H);

####################################
# Step 3. Build and calibrate models 
####################################
my $build_str = ($do_clocal) ? "Building and calibrating models" : "Building models and submitting calibration jobs to the farm";
$start_secs = outputProgressPrior($build_str, $progress_w, $log_FH, *STDOUT);
createCmDb(\%execs_H, $do_cslow, $do_clocal, $all_stk_file, $out_root . ".ref", \@{$mdl_info_HA{"cmname"}}, \%ofile_FH_H);
if(! $do_clocal) { 
  for(my $i = 0; $i < $nmdl; $i++) { 
    addClosedOutputFile(\@ofile_keys_A, \%ofile_name_H, \%ofile_sname_H, \%ofile_desc_H, "cm$i", "$out_root.$i.cm", 
                        sprintf("CM file #%d, %s (currently calibrating on the farm)", $i+1, $mdl_info_HA{"out_tiny"}[$i]), \%ofile_FH_H);
  }
}
else { 
  addClosedOutputFile(\@ofile_keys_A, \%ofile_name_H, \%ofile_sname_H, \%ofile_desc_H, "cm", "$out_root.cm", 
                      "CM file with all $nmdl models", \%ofile_FH_H);
}

outputProgressComplete($start_secs, undef,  $log_FH, *STDOUT);

# a quick note to the user about what to do next
outputString($log_FH, 1, sprintf("#\n"));
if(! $do_clocal) { 
  outputString($log_FH, 1, "# When the $nmdl cmcalibrate jobs on the farm finish, you can use dnaorg_annotate.pl\n");
  outputString($log_FH, 1, "# to use them to annotate genomes.\n");
}
else { 
  outputString($log_FH, 1, "# You can now use dnaorg_annotate.pl to annotate genomes with the models\n");
  outputString($log_FH, 1, "# you've created here.\n");
}
outputString($log_FH, 1, sprintf("#\n"));

##########
# Conclude
##########
$total_seconds += secondsSinceEpoch();
outputConclusionAndCloseFiles($total_seconds, $dir, \@ofile_keys_A, \%ofile_desc_H, \%ofile_sname_H, \%ofile_FH_H);

exit 0;

