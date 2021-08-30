#!/bin/bash
set -e

# 1 {input.ncbi2ucsc}
# 2 {input.ucsc2ncbi}
# 3 {input.vcf_file}
# 4 {wildcards.vcf}
# 5 {input.bam_file}
# 6 {output.snvs_filename}
# 7 {config[tools][bcftoolsCmd]}
# 8 {config[tools][samtoolsCmd]}

ncbi2ucsc=$1
ucsc2ncbi=$2
vcf_file=$3
vcf_id=$4
bam_file=$5
output=$6
bcftools=$7
samtools=$8

tmp=$(mktemp)

echo 'Filter SNVs'

# if not doing QC
if [ $vcf_id != 'QC' ]; then 
	# match the sampleID from the vcf file
    sample_flag="-s ${vcf_id}"
	# pattern to find the headers and heterozygous genotypes
    grep_pattern='grep -w "^#\|^#CHROM\|0|1\|1|0\|0/1\|1/0"'
else
	# when doing QC we don't have a match for the sample
    sample_flag=""
	# when doing QC we want all of our QC variants. so concat instead of grep
    grep_pattern='cat'
fi

# view the vcf file and remove the info header information and the set the INFO column to '.'
# split any multi-allelic lines
# pull out the sample and only the snps that have at least 2 reads supporting it
# use the grep_pattern defined above to pull out the header and heterozygous variants
# zip and save as tmp file
$bcftools view  $vcf_file | \
    grep -vP '^##INFO=' | \
    awk -F'\t' 'BEGIN {OFS = FS} { if($1 ~ /^[^#]/){ $8 = "." }; print $0 }' | \
    $bcftools norm -m-both | \
    $bcftools view ${sample_flag} -m2 -M2 -v snps | \
    eval ${grep_pattern} |bgzip -c > $tmp
$bcftools index -t $tmp

# compare and correct chromosome format mismatch
bam_chr=$($samtools idxstats ${bam_file} | cut -f1 | grep "^chr" | wc -l)
vcf_chr=$($bcftools index --stats $tmp   | cut -f1 | grep "^chr" | wc -l)

if [ ${vcf_chr} -eq 0  ] && [ ${bam_chr} -ne 0 ]  # VCF: UCSC, BAM: NCBI
then
    echo "converting from NCBI to UCSC format"
    $bcftools annotate --rename-chrs $ncbi2ucsc $tmp | bgzip > ${output}
    rm ${tmp}
    rm ${tmp}.tbi
elif [ ${vcf_chr} -ne 0  ] && [ ${bam_chr} -eq 0 ]  # VCF: NCBI, BAM: UCSC
then
    echo "converting from UCSC to NCBI format"
    $bcftools annotate --rename-chrs $ucsc2ncbi $tmp | bgzip > ${output}
    rm ${tmp}
    rm ${tmp}.tbi
else  # VCF and BAM have same chromosome format
    mv $tmp ${output}
    rm ${tmp}.tbi
fi

num_out=$(zcat "${output}" | grep -vc '#' )
if [ "${num_out}" -eq 0 ]
then
  printf  "%s\n" "" "ERROR: No entries after filtering for SNVs" \
  "  Make sure that the VCF file is correctly formatted and contains heterozygous variants." \
  "  This analysis is independent per sample, so consider removing the sample from your analysis as a last resort." \
  "" "  VCF ID: ${vcf_id}" \
  "  VCF file: ${vcf_file}" \
  "  BAM file: ${bam_file}"
  exit 1
fi

$bcftools index -t ${output}

