#!/usr/bin/env Rscript

# Script to design primers for the amplification of nuclear SNVs from 3' 10x scRNAseq cDNA

# parse command line arguments ---------------------------------------------------------------------

library(optparse)
library(tidyverse)
library(GenomicRanges)
library(GenomicFeatures)
library(Seurat)
library(BiocParallel)
library(rtracklayer)
library(BSgenome)
library(TAPseq)
library(ballgown)
library(purrr)
library(TxDb.Hsapiens.UCSC.hg38.knownGene)
library(BSgenome.Hsapiens.UCSC.hg38)
library(BSgenome)
library(mygene)
library(parallel)

# create arguments list
option_list = list(
  make_option(c("-i", "--input_csv"), type = "character", default = NULL,
              help = "csv file with the mutations of interest. It must contain the following 3 columns: 
                      CHROM: chromosome,
                      POS: position,
                      symbol: gene name",
              metavar = "character"),
  make_option(c("-b", "--bam"), type = "character", default = NULL,
              help = "path to 10x BAM file", 
              metavar = "character"),
  make_option(c("-u", "--outdir_gene_exp"), type = "character", default = NULL,
              help = "path to the outs directory generated by 10x. It should include the directory filtered_feature_bc_matrix necessary to make a Seurat object", 
              metavar = "character"),
  make_option(c("-p", "--count_table"), type = "character", default = NULL,
              help = "csv file with RNA count table with gene names as rows and cells as columns. First column should be named gene_names and contain names of genes.
              Only required when cellranger output path is not provided (--outdir_gene_exp option)", 
              metavar = "character"),
  make_option(c("-g", "--gtf_file"), type = "character", default = NULL,
              help = "GTF file from ensembl", 
              metavar = "character"),  
  make_option(c("-n", "--name"), type = "character", default = NULL,
              help = "Sample name", 
              metavar = "character"),  
  make_option(c("-r", "--read_length"), type = "integer", default = NULL,
              help = "Length of read2 in bp", 
              metavar = "character"),  
  make_option(c("-m", "--forced_mutations"), type = "character", default = NULL, 
              help = "txt file gene names (one per line) of mutations for which primers will be designed regardless of the expression or distance to end of gene (optional)", 
              metavar = "character"),   
  make_option(c("-c", "--cores"), type = "integer", default = 8,
              help = "Number of cores (default 8)", metavar = "character"),
  make_option(c("-d", "--out_directory"), type = "character", default = NULL,
              help = "directory where output files will be written", 
              metavar = "character"))

# parse arguments
opt_parser = OptionParser(option_list = option_list)
opt = parse_args(opt_parser)

# function to check for required arguments
check_required_args <- function(arg, opt, opt_parser) {
  
  if (is.null(opt[[arg]])) {
    
    print_help(opt_parser)
    stop(arg, " argument is required!", call. = FALSE)
    
  }
}

# check that all required parameters are provided
required_args <- c("input_csv", "bam", "name", "read_length","out_directory","gtf_file")


for (i in required_args) {
  
  check_required_args(i, opt = opt, opt_parser = opt_parser)
  
}

#function to generate template sequences based on a particular genomic site
get_exons <- function(genomic_sites, contig_list, gene_names, gtf_file, polyAs){
  
  # get transcripts
  gtf_genes <- gffReadGR(gtf_file)
  
  
  # get exons from genes of interest
  target_exons <- gtf_genes[mcols(gtf_genes)[,"type"] == "exon" &
                              mcols(gtf_genes)[,"gene_name"] %in% gene_names] %>% 
    sort()
  
  # put them in a list split by gene name
  exons <- split(target_exons, f = target_exons$gene_name)
  
  
  # make contig names equal
  seqlevelsStyle(exons) <- "UCSC"
  
  # read polyA sites
  polyAs <- import(polyAs)[elementMetadata(import(polyAs))[,"name"] %in% gene_names]

  list_regions <- lapply(1:length(gene_names), function(i){
    
    # get exons from the gene of interest and merge overlapping sequences.
    gene_exons <- exons[[gene_names[i]]]
    
    # convert mutations site to GRanges object
    mutation_site <- GRanges(seqnames = contig_list[i], ranges = genomic_sites[i])
    
    # make seqlevels homogeneous
    seqlevelsStyle(gene_exons) <- seqlevelsStyle(mutation_site) <- "UCSC"
    
    # find which transcripts overlap with the mutation of interest
    overlap <- to(findOverlaps(mutation_site, gene_exons))
    
    # extract overlapping transcripts
    transcripts_overlap <- elementMetadata(gene_exons[overlap][,"transcript_id"]) %>%
      unique() %>% as.data.frame() %>% pull()
    
    # filter out transcripts which do not overlap with the mutations of interest.
    gene_exons <- gene_exons[elementMetadata(gene_exons)[,"transcript_id"] %in% transcripts_overlap]
    
    # I annotated some transcript isoforms with non-canonical exons that I have been observing in some
    # genes. These will be eliminated to make sure that the primers do not fall into this unique exons
    blacklisted_transcripts <- readRDS("data/blacklisted_transcripts.rds")
    
    # filter blacklisted transcripts
    gene_exons <- gene_exons[!elementMetadata(gene_exons)[, "transcript_id"] %in% blacklisted_transcripts]
    
    # if a polyA was selected, then only transcripts which overlap with it are chosen
    if(length(which(polyAs$name == gene_names[i])) != 0){
      
      gene_polyA <- polyAs[elementMetadata(polyAs)[,"name"] == gene_names[[i]]]
      
      # find which transcripts overlap with the selected polyA
      overlap_polyA <- to(findOverlaps(gene_polyA, gene_exons))
      
      # extract overlapping transcripts
      transcripts_overlap <- elementMetadata(gene_exons[overlap_polyA][,"transcript_id"]) %>%
        unique() %>% as.data.frame() %>% pull()
      
      
      # filter out transcripts which do not overlap with the mutations of interest.
      gene_exons <- gene_exons[elementMetadata(gene_exons)[,"transcript_id"] %in% transcripts_overlap]
      
      
    }
    
    
    # merge ovelapping regions 
    gene_exons <- GenomicRanges::sort(GenomicRanges::reduce(gene_exons))
    
    
    # get a unique overlap range between the mutation and the list of exons
    overlap <- to(findOverlaps(mutation_site, gene_exons))
    
    
    # Create a new GRanges object with exomic information upstream of the mutation of interest.
    # The strand information is important in order to generate the sequence template.
    if(as.character(strand(gene_exons[1])@values) == "-"){
      
      # If the mutation is present in the most downstream exon (which for genes in the negative strand is the 1st exon)
      if(overlap == length(gene_exons)){
        
        
        filtered_region <- GenomicRanges::sort(GRanges(seqnames = contig_list[i], 
                                                       ranges = IRanges(start = start(mutation_site), end = end(gene_exons[overlap])),
                                                       strand = as.character(strand(gene_exons[1])@values)), decreasing = T)
        
      }else{
        
        
        filtered_region <- GenomicRanges::sort(c(GRanges(seqnames = contig_list[i], 
                                                         ranges = IRanges(start = start(mutation_site), end = end(gene_exons[overlap])),
                                                         strand = as.character(strand(gene_exons[1])@values)),
                                                 gene_exons[(overlap+1):length(gene_exons)]), decreasing = T)
        
      }
      
    }else{
      
      
      if(overlap == 1){
        
        
        filtered_region <- GenomicRanges::sort(GRanges(seqnames = contig_list[i], 
                                                       ranges = IRanges(start = start(gene_exons[overlap]), end = start(mutation_site)),
                                                       strand = as.character(strand(gene_exons[1])@values)), decreasing = F)
        
      }else{
        
        
        filtered_region <- GenomicRanges::sort(c(gene_exons[1:(overlap-1)], 
                                                 GRanges(seqnames = contig_list[i], 
                                                         ranges = IRanges(start = start(gene_exons[overlap]), end = start(mutation_site)),
                                                         strand = as.character(strand(gene_exons[1])@values))), decreasing = F)
      }
    }
    
  })
  
  return(list_regions)
  
}


# code to run the script .............................................................................

# read table with variants
raw_variants <- read_csv(opt$input_csv)

# extract symbols from genes of interest
gene_names <- raw_variants$symbol %>% unique()

# read gene annotation from gtf file to data frame
gtf_genes <- gffReadGR(opt$gtf_file)

# create out directory
suppressWarnings(dir.create(opt$out_directory))

# GET GENE EXPRESSION ---------------------------------------------------------------------

message("Computing expression of genes")

# if count table is provided compute mean gene expression for the genes of interest
if("count_table" %in% names(opt)){
  
    count_table <- read_csv(opt$count_table) %>% 
                      filter(gene_names %in% gene_names) %>% 
                      column_to_rownames(var = "gene_names")
    
    total_cells <- ncol(count_table)
    
    gene_expression <- data.frame(symbol = rownames(count_table),
                                  counts_cell = rowSums(count_table)/total_cells)
  
}else{
  
    # create seurat object
    count_data <- Read10X(data.dir = paste0(opt$outdir_gene_exp,"/filtered_feature_bc_matrix/"))
    if(is.list(count_data)){
      
      count_matrix <- CreateSeuratObject(counts = count_data$`Gene Expression`)
      
    }else{count_matrix <- CreateSeuratObject(counts = count_data)}
    
    # compute total number of cells
    total_cells <- ncol(count_matrix)
    
    # filter genes which are present in the counts matrix
    gene_names <- gene_names[which(gene_names %in% rownames(count_matrix))]
    
    # get raw counts for genes of interest
    counts <- count_matrix@assays$RNA@counts[gene_names,] %>% 
      rowSums()
    
    
    # divide counts by the total number of cells
    gene_expression <- data.frame(symbol = names(counts),
                                  counts_cell = counts/total_cells)
    
}


# Subset BAM file for gene targets -----------------------------------------------------------------------------

# get transcript coordinates for the genes in the variant table
filtered_transcripts <- gtf_genes[elementMetadata(gtf_genes)[,"gene_name"] %in% gene_names]

# change seqlevels to UCSC
seqlevelsStyle(filtered_transcripts) <- "UCSC"

# eliminate metadata column in order to save the coordinates into a BED file
mcols(filtered_transcripts) <- NULL

# create directory to store genomic files (bed, bam and gtf to load on IGV)
gen_dir <- paste0(opt$out_directory, "/genomic_files")
suppressWarnings(dir.create(gen_dir))

if(!file.exists(paste0(gen_dir, "/subsetted.bam"))){
  
  message("Subsetting BAM file for polyA estimation")
  
  # export gene coordinates as BED file
  export(filtered_transcripts, con = paste0(gen_dir, "/full_length_genes.bed"), format = "bed")
  
  # subset BAM file for the genes of interest
  system(paste("samtools view -h -b -L", paste0(gen_dir, "/full_length_genes.bed"), opt$bam, ">", 
               paste0(gen_dir, "/subsetted.bam")))
  
  # index subset BAM file
  system(paste("samtools index -b", paste0(gen_dir, "/subsetted.bam")))
  
}else{message("Subsetted BAM already present!")}

# DISTANCE TO polyA ---------------------------------------------------------------------

message("Computing distance to polyA")

# get gene names
genes_mut_exons <- raw_variants$symbol %>% unique()

# put mutations in GRanges object
mutations <- unlist(GRangesList(lapply(1:nrow(raw_variants), function(i){
  
  range <- GRanges(seqnames = raw_variants$CHROM[i], ranges = raw_variants$POS[i])
  
})))

# get exons from genes of interest
target_genes <- gtf_genes[mcols(gtf_genes)[,"type"] == "exon" &
                            mcols(gtf_genes)[,"gene_name"] %in% genes_mut_exons] %>% sort()

# make seqlevels style equal
seqlevelsStyle(mutations) <- seqlevelsStyle(target_genes) <- "UCSC"

# get exons which overlap with the mutations of interest
exons_overlap <- to(findOverlaps(mutations, target_genes))

# extract overlapping transcripts
transcripts_overlap <- elementMetadata(target_genes[exons_overlap][,"transcript_id"]) %>%
                        unique() %>% as.data.frame() %>% pull()


# filter out transcripts which do not overlap with the mutations of interest.
target_genes <- target_genes[elementMetadata(target_genes)[,"transcript_id"] %in% transcripts_overlap]

# remove exons longer than 1kb. The 1st and last segments are excluded as they
# corresponded to the 3'-UTR and 5'-UTR 
filtered_exons <- mclapply(1:length(transcripts_overlap), function(i){
  
  # get exons from a particular transcript
  exons <- target_genes[elementMetadata(target_genes)[,"transcript_id"] == transcripts_overlap[i]]
  
  # check if any of the exons is longer than 1kb
  if(length(exons) == length(unique(c(1, which(width(ranges(exons))<1000), length(exons))))){
    
    filtered_ranges <- exons
    
    exons_excluded <- FALSE
    
    # if large exons are present and do not overlap with the mutation they are eliminated
  }else{exons_excluded <- TRUE
  
  # determine if any of the mutations fall into the exons
  overlap <- to(findOverlaps(mutations, exons))
  
  # filter out long exons
  filtered_ranges <- exons[unique(sort(c(1, which(width(ranges(exons))<1000), overlap, length(exons))))]
  
  }
  
  return(list(exons_filtered = exons_excluded, ranges = filtered_ranges))
  
}, mc.cores = opt$cores)

# merge filtered exons in single GRanges object
target_exons <- unlist(GRangesList(map(filtered_exons,2)))

# split GRanges exons by gene name
target_exons <- split(target_exons, f = target_exons$gene_name)

# extract genes for which exons were excluded in order to later on flag the genes
exon_flags <- target_genes[elementMetadata(target_genes)[,"transcript_id"] %in%
                             transcripts_overlap[which(unlist(map(filtered_exons, 1)))]] %>% 
                    .$gene_name %>% unique()

# set the number of cores to infer polyA site. 
register(MulticoreParam(workers = opt$cores))

# infer polyA sites. With the subsetted BAM it takes a few seconds
polyA_sites <- inferPolyASites(target_exons,
                               bam = paste0(gen_dir, "/subsetted.bam"), 
                               polyA_downstream = 50, by = 1,
                               wdsize = 100, min_cvrg = 100, parallel = TRUE)

# add gene names as metadata column to the GRanges object
polyA_sites$gene_name <- names(polyA_sites)

# split polyAs by gene
polyA_sites <- split(polyA_sites, f = polyA_sites$gene_name)

# function to select the smallest positive value
min_pos <- function(x){min(x[x>0])}

# select a unique polyA per gene
polyAs <- lapply(1:length(polyA_sites), function(i){
  
  gene_ends <- polyA_sites[[i]]
  
  # set polyA score threshold as half of the maximum score by the top ranked polyA
  threshold <- max(gene_ends$score)/2
  
  # set a minimum threshold of 400 
  #if (threshold < 400){threshold <- 400}
  
  # when only one polyA has a score a above the threshold
  if(length(which(elementMetadata(gene_ends)[,"score"] > threshold)) == 1){
    
    
    tail_candidates <- gene_ends[which(elementMetadata(gene_ends)[,"score"] > threshold)]
    
    mutation_position <- raw_variants %>% filter(symbol %in% names(gene_ends)) %>% 
      pull(POS) %>% as.integer()
    
    polyA_flag <- FALSE
    
    # the strand is important when it comes to computing distances
    if(strand(tail_candidates)@values == "+"){
      
      distances <- ranges(tail_candidates)@start-mutation_position
      
      # if the inferred polyA  upstream of the mutation a flag is raised
      if(min_pos(distances) == Inf){
        
        selected_tail <- NULL
        
        # if the polyA is downstream then is selected
      }else{selected_tail <- tail_candidates}
      
    }else{
      
      distances <- (ranges(tail_candidates)@start-mutation_position)*(-1)
      
      # if all inferred polyA is upstream of the mutation a flag is raised
      if(min_pos(distances) == Inf){
        
        selected_tail <- NULL
        
        # if the polyA is downstream then is selected
      }else{selected_tail <- tail_candidates}      
    }
    # if 2 or more polyAs have a score higher than 50 I pick the one closer to the mutation site.
  }else if(length(which(elementMetadata(gene_ends)[,"score"] > threshold)) > 1){
    
    tail_candidates <- gene_ends[which(elementMetadata(gene_ends)[,"score"] > threshold)]
    
    mutation_position <- raw_variants %>% filter(symbol %in% names(gene_ends)) %>% 
      pull(POS) %>% as.integer()
    
    polyA_flag <- TRUE
    
    # if there are more than 1 mutation in a particular gene I take the most downstream mutation
    if(length(mutation_position) > 1){
      
      # the strand is important when it comes to computing distances
      if(strand(tail_candidates)@values == "+"){
        
        # take the most downstream mutation
        mutation_position <- max(mutation_position)
        
        distances <- ranges(tail_candidates)@start-mutation_position
        
        # if all the inferred polyAs are upstream of the mutations a flag is raised
        if(min_pos(distances) == Inf){
          
          polyA_flag <- FALSE
          
          selected_tail <- NULL
          
          # if the polyA is downstream the is selected
        }else{selected_tail <- tail_candidates[which(distances %in% min_pos(distances))]}
      }else{
        # the most downstream mutation is in this case the one with a lower position due to the - strand
        mutation_position <- min(mutation_position)
        
        distances <- (ranges(tail_candidates)@start-mutation_position)*(-1)
        
        # if all the inferred polyAs are upstream of the mutations a flag is raised
        if(min_pos(distances) == Inf){
          
          polyA_flag <- FALSE
          
          selected_tail <- NULL
          
          # if the polyA is downstream the is selected
        }else{selected_tail <- tail_candidates[which(distances %in% min_pos(distances))]}
      } 
    # when there is only one mutation/gene, it gets automatically selected.  
    }else{
      
      # the strand is important when it comes to computing distances
      if(strand(tail_candidates)@values == "+"){
        
        distances <- ranges(tail_candidates)@start-mutation_position
        
        # if all the inferred polyAs are upstream of the mutations a flag is raised
        if(min_pos(distances) == Inf){
          
          polyA_flag <- FALSE
          
          selected_tail <- NULL
          
          # if the polyA is downstream the is selected
        }else{selected_tail <- tail_candidates[which(distances %in% min_pos(distances))]}
        
      }else{
        
        distances <- (ranges(tail_candidates)@start-mutation_position)*(-1)
        
        # if all the inferred polyAs are upstream of the mutation a flag is raised
        if(min_pos(distances) == Inf){
          
          polyA_flag <- FALSE
          
          selected_tail <- NULL
          
          # if the polyA is downstream the is selected
        }else{selected_tail <- tail_candidates[which(distances %in% min_pos(distances))]}                
      } 
    }
  }else{return(NULL)}
  
  return(list(ranges = selected_tail, flags = polyA_flag))
  
})

# select genes with a polyA detected
filt_polyAs <- polyAs[which(lengths(map(polyAs, 1)) == 1)]

# put all polyAs in one GRanges object
final_polyAs <-  unlist(GRangesList(map(filt_polyAs,1)))

# genes for which no polyA was found
genes_no_polyA <- genes_mut_exons[!genes_mut_exons %in% final_polyAs$gene_name]

# truncate transcripts at the inferred polyA sites
target_transcripts <- GenomicRanges::sort(GenomicRanges::reduce(truncateTxsPolyA(target_exons, 
                                                                                 polyA_sites = final_polyAs, 
                                                                                 parallel = TRUE,
                                                                                 transcript_id = "transcript_id"))) 

# get genes with multiple_polyA flag
polyAs_flag <- names(polyA_sites)[which(unlist(map(polyAs,2)))]
print("For the following genes more than one polyA was detected:")
print(polyAs_flag)
print("For the following genes no polyA was detected:")
print(genes_no_polyA)

# EXPORT BED FILES ----------------------------------------------------------------------

# create directory where bed files will be stored

if(dir.exists(opt$out_directory) == F){
  
  dir.create(opt$out_directory)
  
}

## It is recommended to check the PolyA tails in IGV manually. 
# add gene names to the polyA object (only name and score columns are exported to the final bed file)
final_polyAs$name <- final_polyAs$gene_name

# export polyAs to bed file to manually check in IGV
export(unlist(polyA_sites), con = paste0(gen_dir, "/polyA_candidates.bed"), format = "bed")

# export target gene annotations to load in IGV
export(unlist(target_exons), con = paste0(gen_dir, "/target_genes.gtf"), format = "gtf")

# export mutations to BED file in order to load in IGV
mut_bed <- GRanges(seqnames = raw_variants$CHROM,
                   ranges = IRanges(start = as.integer(raw_variants$POS), 
                                    end = as.integer(raw_variants$POS)))
export(mut_bed, con = paste0(gen_dir, "/mutations.bed"), format = "bed")

# export final selection of polyA sites
export(final_polyAs, con = paste0(gen_dir, "/polyA_final_selection.bed"), format = "bed")

# COMPUTE DISTANCE TO THE polyA tail ---------------------------------------------------------

message("Computing distance to polyA")

# locate the mutation among the exons
list_regions <- lapply(1:length(raw_variants$symbol), function(i){
  
  # if the gene is not found in the gtf file then no polyA distance can be computed
  if(raw_variants$symbol[[i]] %in% names(target_transcripts)){
    
    # Get exons from the gene of interest and merge overlapping sequences.
    exons <- target_transcripts[[raw_variants$symbol[i]]]
    seqlevelsStyle(exons) <- "UCSC"
    
    # Find where the mutation of interest is in the exon ranges
    mutation_site <- GRanges(seqnames = raw_variants$CHROM[i], ranges = raw_variants$POS[i])
    seqlevelsStyle(mutation_site) <- "UCSC"
    overlap <- to(findOverlaps(mutation_site, exons))
    
    # create a new GRanges object with exomic information upstream of the mutation of interest
    # the strand information is important in order to generate the sequence template
    # if the mutation is not mapped into any exonic region it should be reported
    
    if(length(overlap) == 1){
      
      if(runValue(strand(exons[1])) == "-"){
        
        if(overlap == 1){
          
          filtered_region <- GRanges(seqnames = runValue(seqnames(exons)), 
                                     ranges = IRanges(start = start(exons[overlap]), 
                                                      end = start(mutation_site)),
                                     strand = as.character(strand(exons[1])@values))
          
        }else{
          
          filtered_region <- c(exons[1:(overlap-1)],
                               GRanges(seqnames = runValue(seqnames(exons)), 
                                       ranges = IRanges(start = start(exons[overlap]), 
                                                        end = start(mutation_site)),
                                       strand = as.character(strand(exons[1])@values)))
        }
        
      }else{
        if(overlap == length(exons)){
          
          filtered_region <- GRanges(seqnames = runValue(seqnames(exons)), 
                                     ranges = IRanges(start = start(mutation_site), 
                                                      end = end(exons[overlap])),
                                     strand = as.character(strand(exons[1])@values))
          
        }else{
          
          filtered_region <- c(GRanges(seqnames = runValue(seqnames(exons)), 
                                       ranges = IRanges(start = start(mutation_site), 
                                                        end = end(exons[overlap])),
                                       strand = as.character(strand(exons[1])@values)),
                               exons[(overlap+1):length(exons)])
        }
      }
      
    }else{message(paste0(raw_variants$symbol[i], " ", i,
                         ": Mutation does not overlap with exonic regions! Check polyA sites in IGV."))}
    
    
  }else{filtered_region <- GRanges()}
  
  
})


# add gene names 
names(list_regions) <- paste(raw_variants$symbol, raw_variants$CHROM, raw_variants$POS, 
                             sep = "_")

# remove genes for which no overlap between exons and mutation was found
list_regions <- list_regions[lengths(list_regions) != 0]

# get sequence from the generated regions
hg38 <- getBSgenome("BSgenome.Hsapiens.UCSC.hg38")
txs_seqs <- getTxsSeq(GRangesList(list_regions), genome = hg38)

# extract distance to the 3'-end for each gene
distance_table <- tibble(symbol = names(txs_seqs),
                         distance_3_end = width(txs_seqs)) %>% 
                      separate(symbol, into = c("symbol", "CHROM","POS"), sep = "_") %>% 
                      mutate(POS = as.integer(POS))


# ANNOTATED TABLE --------------------------------------------------------------

annotated_variants <- raw_variants %>% 
                        mutate(POS = as.integer(POS)) %>% 
                        left_join(distance_table) %>% 
                        left_join(gene_expression) 

# add flags column
flag_vector <- sapply(1:length(unique(raw_variants$symbol)), function(x){
  
  x <- unique(raw_variants$symbol)[x]
  
  flag_vector <- vector()
  
  if(x %in% exon_flags){
    
    flag_vector <- "long_exon_excluded"
  }
  
  if(!x %in% names(final_polyAs)){
    
    flag_vector <- c(flag_vector, "no_polyA_found")
  }
  
  if(x %in% polyAs_flag){
    
    flag_vector <- c(flag_vector, "multiple_polyAs")
  }
  
  return(paste(flag_vector, collapse = ";"))
  
})

flag_table <- data.frame(flag = flag_vector,
                         symbol = unique(raw_variants$symbol))

# mutations to design primers for regardles of expression or distance to polyA (user-defined)
if(!is.null(opt$forced_mutations)){
  
  muts <- read_delim(opt$forced_mutations, delim = "\n", col_names = F) %>% pull(X1)
  
}else{muts <- ""}

# order columns in the table depending on the format
# add flags to the table
annotated_variants <- annotated_variants %>% left_join(flag_table) %>% 
                          mutate(flag = if_else(counts_cell < 0.1, 
                                                paste(flag, "low_expressed", sep = ";"), flag),
                                 flag = if_else(flag == "", "PASS", flag)) %>% 
                          dplyr::select(symbol, CHROM, POS, counts_cell, distance_3_end, flag) %>% 
                          arrange(distance_3_end) %>% 
                          mutate(primers = ifelse(counts_cell > 0.15 & distance_3_end < 1500 | symbol %in% muts, T, F),
                                 reason = case_when(primers == T ~ "primers_designed",
                                                    primers == F & counts_cell < 0.15 ~ "low_expression",
                                                    primers == F & distance_3_end > 1500 ~ "far_from_gene_end")) %>% 
                          dplyr::arrange(distance_3_end)
                          
# make directory to store primer file
primer_dir <- paste0(opt$out_directory, "/primers")
suppressWarnings(dir.create(primer_dir))

# save the annotated table
write_csv(annotated_variants, file = paste0(primer_dir, "/annotated_variants.csv"))

# DESIGN PRIMERS ---------------------------------------------------------------------------------

message("Designing primers")

# filter variants
hits_table <- annotated_variants %>% filter(primers == T)

polyA_bed <- paste0(gen_dir, "/polyA_final_selection.bed")

# compute regions
regions_list <- get_exons(genomic_sites = hits_table$POS, contig_list = hits_table$CHROM, 
                                gene_names = hits_table$symbol, gtf_file = opt$gtf_file,
                                polyAs = polyA_bed)

# put sequences into a GRangesList
ranges_list <- GRangesList(regions_list)

# name each item with gene name
names(ranges_list) <- hits_table$symbol

# load genome
hg38 <- getBSgenome("BSgenome.Hsapiens.UCSC.hg38")

# get 5'-UTR and exons upstream of the mutation of interest 
sequences <- getTxsSeq(ranges_list, hg38)

# create outer primers. the read1, cell barcode and UMI are automatically added upstream of the 3'-end and account for 81bp 
# the outer primer lies 250-350 bp away from the mutation
# it can be that for short genes and mutations which are very upstream there is not enough RNA body to create the outer primers
outer_primers <- TAPseqInput(sequences,
                             product_size_range = c((90+250), (90+350)), 
                             primer_num_return = 5,
                             target_annot = ranges_list)
outer_primers <- designPrimers(outer_primers)

# create middle primers. 
# The primers lie between 100 and 200 bp away from the 3'-end of the transcript
message("Designing middle primers")
middle_primers <- TAPseqInput(sequences,
                              product_size_range = c((90+100), (90+200)), 
                              primer_num_return = 5,
                              target_annot = ranges_list)
middle_primers <- designPrimers(middle_primers)

# create inner primers. 
# this align between the 9 bp before the mutation and a maximum of bp = read_length-10 upstream 
message("Designing inner primers")
inner_primers <- TAPseqInput(sequences,
                             product_size_range = c(90, 90+opt$read_length-15), 
                             primer_num_return = 5,
                             target_annot = ranges_list)
inner_primers <- designPrimers(inner_primers)

# pick puter primers based on the penalty score
best_outer_primers <- pickPrimers(outer_primers, by = "penalty")

# pick middle primers based on the penalty score
best_middle_primers <- pickPrimers(middle_primers, by = "penalty")

# pick inner primers based on penalty score
best_inner_primers <- pickPrimers(inner_primers, by = "penalty")

message("Writing primers to output files")

# final data frame with column stating distance to the mutation
# the fragment length after each PCR is also specified
primers_table <- rbind(primerDataFrame(best_outer_primers) %>% mutate(primer_id = paste0(primer_id, "_outer")),
                       primerDataFrame(best_middle_primers) %>% mutate(primer_id = paste0(primer_id, "_middle")),
                       primerDataFrame(best_inner_primers) %>% mutate(primer_id = paste0(primer_id, "_inner"))) %>%
                        arrange(primer_id) %>% 
                        mutate(distance_mutation = pcr_product_size-90) %>%
                        dplyr::rename(symbol = seq_id) %>%
                        left_join(hits_table %>% dplyr::select(symbol, distance_3_end)) %>%
                        mutate(fragment_length = distance_mutation+distance_3_end+90) %>%
                        dplyr::select(-distance_3_end)


# write final table as csv
write_csv(primers_table, file = paste0(primer_dir, "/primer_details.csv"))

# export primers as BED ranges
exportPrimerTrack(createPrimerTrack(best_outer_primers, color = "steelblue3"),
                  createPrimerTrack(best_middle_primers, color = "green"),
                  createPrimerTrack(best_inner_primers, color = "red"),
                  con = paste0(primer_dir,"/primers.bed"))

# add commands to include the adaptor and stagger sequences into the inner primers
staggered_primers <- lapply(1:length(hits_table$symbol), function(i){
  
  # get sequence of outer primer
  outer_sequence <- primers_table %>% filter(symbol == hits_table$symbol[i]) %>% dplyr::slice(3) %>%
    pull(sequence)
  
  # get sequence of middle primer
  middle_sequence <- primers_table %>% filter(symbol == hits_table$symbol[i]) %>% dplyr::slice(2) %>%
    pull(sequence)
  
  
  # get sequence of inner primer
  inner_sequence <- primers_table %>% filter(symbol == hits_table$symbol[i]) %>% dplyr::slice(1) %>%
    pull(sequence)
  
  
  # create staggered primers by adding partial Read2 handle + stagger
  staggered_primers <- c(paste0("CACCCGAGAATTCCA", inner_sequence),
                         paste0("CACCCGAGAATTCCAA", inner_sequence),
                         paste0("CACCCGAGAATTCCATT", inner_sequence),
                         paste0("CACCCGAGAATTCCACAT", inner_sequence))
  
  
  # generate a table with the final sequences
  complete_table <- data.frame(primer_name = paste(opt$name, hits_table$symbol[i], 
                                                   c("inner_1", "inner_2", "inner_3", "inner_4", "middle", "outer"),
                                                   sep = "_"),
                               sequence = c(staggered_primers, middle_sequence, outer_sequence))
  
  complete_table
  
})

# create a table with primer sequences for all target mutations
complete_primer_table <- do.call("bind_rows", staggered_primers)

# export table as csv
write_csv(complete_primer_table, file = paste0(primer_dir, "/primer_sequences.csv"))

message("Done!")
