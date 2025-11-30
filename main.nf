#!/usr/bin/env nextflow

params.outdir = params.outdir ?: "results"

process tiny_test {
    publishDir params.outdir, mode: 'copy'
    """
    echo 'Hello from tiny test' > test.txt
    """
}

workflow {
    tiny_test()
}
