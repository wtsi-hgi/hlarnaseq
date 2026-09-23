# wtsi-hgi/hlarnaseq: Citations

## [nf-core](https://pubmed.ncbi.nlm.nih.gov/32055031/)

> Ewels PA, Peltzer A, Fillinger S, Patel H, Alneberg J, Wilm A, Garcia MU, Di Tommaso P, Nahnsen S. The nf-core framework for community-curated bioinformatics pipelines. Nat Biotechnol. 2020 Mar;38(3):276-278. doi: 10.1038/s41587-020-0439-x. PubMed PMID: 32055031.

## [Nextflow](https://pubmed.ncbi.nlm.nih.gov/28398311/)

> Di Tommaso P, Chatzou M, Floden EW, Barja PP, Palumbo E, Notredame C. Nextflow enables reproducible computational workflows. Nat Biotechnol. 2017 Apr 11;35(4):316-319. doi: 10.1038/nbt.3820. PubMed PMID: 28398311.

## Pipeline tools

## [arcasHLA](https://doi.org/10.1093/bioinformatics/btz474)

> Orenbuch R, Filip I, Comito D, Shaman J, Pe'er I, Rabadan R. arcasHLA: high-resolution HLA typing from RNAseq. Bioinformatics. 2020 Jan 1;36(1):33-40. doi: 10.1093/bioinformatics/btz474.

## [HLA-LA](https://doi.org/10.1093/bioinformatics/btz235)

> Dilthey AT, Mentzer AJ, Carapito R, Cutland C, Cereb N, Madhi SA, Rhie A, Koren S, Bahram S, McVean G, Phillippy AM. HLA\*LA-HLA typing from linearly projected graph alignments. Bioinformatics. 2019 Nov 1;35(21):4394-4396. doi: 10.1093/bioinformatics/btz235.

## [HIBAG](https://doi.org/10.1038/tpj.2013.18)

> Zheng X, Shen J, Cox C, Wakefield JC, Ehm MG, Nelson MR, Weir BS. HIBAG-HLA genotype imputation with attribute bagging. Pharmacogenomics J. 2014 Apr;14(2):192-200. doi: 10.1038/tpj.2013.18.
>
> The published pre-fit models fetched by `testdata-make/11-download-hibag-model` (the "HLARES" parameter estimates, from GlaxoSmithKline clinical trials and HapMap Phase 2) are distributed with this paper at https://hibag.s3.amazonaws.com/. Upstream states no licence for them, only a request to cite the publication above; they are downloaded into gitignored test data and are not redistributed by this pipeline.

## [HLApm](https://github.com/davenportlab/HLApm)

> Davenport Lab. HLApm: personalized HLA reference building for bulk and single-cell RNA-seq. GitHub repository: https://github.com/davenportlab/HLApm. No published paper or DOI was found for this tool at the time this citation was added; this entry is provisional pending a published reference. HLApm publishes no releases or tags, so this pipeline pins it by commit: `38faa6087bbd827ccab969d947f8df101e95d688` (2025-06-17), the version baked into `HLAPM_BUILD_REF`'s container image.

## [davenportlab/HLApm_farm_pipeline](https://github.com/davenportlab/HLApm_farm_pipeline)

> Davenport Lab. HLApm_farm_pipeline: farm-oriented processing scripts accompanying HLApm, including `04_04_24_summarize_readcounts_script.R`, the basis for this pipeline's `bin/summarize_hla_readcounts.R` gene-level read-count summarization script. GitHub repository: https://github.com/davenportlab/HLApm_farm_pipeline. No published paper or DOI was found for this tool at the time this citation was added; this entry is provisional pending a published reference.

## [pybam](https://github.com/JohnLonginotto/pybam)

> Longinotto J. pybam: a pure-Python BAM file reader. GitHub repository: https://github.com/JohnLonginotto/pybam. No published paper or DOI was found for this tool at the time this citation was added; this entry is provisional pending a published reference. pybam publishes no releases, tags or PyPI package, so this pipeline pins it by commit: `846d98603905c57c31bf7b9abaf2eb8c89899e60`, the version installed into `HLAPM_QUANTIFY_READS`'s container image.

## [intervaltree](https://pypi.org/project/intervaltree/)

> Tretyakov K, Halbert CL. intervaltree: Editable interval tree data structure for Python. PyPI package: https://pypi.org/project/intervaltree/. No published paper or DOI was found for this tool at the time this citation was added; this entry is provisional pending a published reference. Pinned to version 3.1.0; `make_a_table_210804_allHLAgenes.py` can also use `quicksect` instead, which this pipeline deliberately does not install.

## [validatefastq](https://github.com/biopet/validatefastq)

> Biopet team, Leiden University Medical Center. validatefastq: validate a FASTQ file, or a pair of FASTQ files, checking record structure, duplicate reads, matching mate headers and counts, and quality encoding. Packaged for Bioconda as `biopet-validatefastq`. GitHub repository: https://github.com/biopet/validatefastq. No published paper or DOI was found for this tool at the time this citation was added; this entry is provisional pending a published reference.

## [SAMtools](https://doi.org/10.1093/gigascience/giab008)

> Danecek P, Bonfield JK, Liddle J, Marshall J, Ohan V, Pollard MO, Whitwham A, Keane T, McCarthy SA, Davies RM, Li H. Twelve years of SAMtools and BCFtools. GigaScience. 2021;10(2):giab008. doi: 10.1093/gigascience/giab008.

## [STAR](https://doi.org/10.1093/bioinformatics/bts635)

> Dobin A, Davis CA, Schlesinger F, Drenkow J, Zaleski C, Jha S, Batut P, Chaisson M, Gingeras TR. STAR: ultrafast universal RNA-seq aligner. Bioinformatics. 2013 Jan 1;29(1):15-21. doi: 10.1093/bioinformatics/bts635.

## [featureCounts (Subread)](https://doi.org/10.1093/bioinformatics/btt656)

> Liao Y, Smyth GK, Shi W. featureCounts: an efficient general purpose program for assigning sequence reads to genomic features. Bioinformatics. 2014 Apr 1;30(7):923-30. doi: 10.1093/bioinformatics/btt656.

## Software packaging/containerisation tools

- [Anaconda](https://anaconda.com)

  > Anaconda Software Distribution. Computer software. Vers. 2-2.4.0. Anaconda, Nov. 2016. Web.

- [Bioconda](https://pubmed.ncbi.nlm.nih.gov/29967506/)

  > Grüning B, Dale R, Sjödin A, Chapman BA, Rowe J, Tomkins-Tinch CH, Valieris R, Köster J; Bioconda Team. Bioconda: sustainable and comprehensive software distribution for the life sciences. Nat Methods. 2018 Jul;15(7):475-476. doi: 10.1038/s41592-018-0046-7. PubMed PMID: 29967506.

- [BioContainers](https://pubmed.ncbi.nlm.nih.gov/28379341/)

  > da Veiga Leprevost F, Grüning B, Aflitos SA, Röst HL, Uszkoreit J, Barsnes H, Vaudel M, Moreno P, Gatto L, Weber J, Bai M, Jimenez RC, Sachsenberg T, Pfeuffer J, Alvarez RV, Griss J, Nesvizhskii AI, Perez-Riverol Y. BioContainers: an open-source and community-driven framework for software standardization. Bioinformatics. 2017 Aug 15;33(16):2580-2582. doi: 10.1093/bioinformatics/btx192. PubMed PMID: 28379341; PubMed Central PMCID: PMC5870671.

- [Docker](https://dl.acm.org/doi/10.5555/2600239.2600241)

  > Merkel, D. (2014). Docker: lightweight linux containers for consistent development and deployment. Linux Journal, 2014(239), 2. doi: 10.5555/2600239.2600241.

- [Singularity](https://pubmed.ncbi.nlm.nih.gov/28494014/)

  > Kurtzer GM, Sochat V, Bauer MW. Singularity: Scientific containers for mobility of compute. PLoS One. 2017 May 11;12(5):e0177459. doi: 10.1371/journal.pone.0177459. eCollection 2017. PubMed PMID: 28494014; PubMed Central PMCID: PMC5426675.
