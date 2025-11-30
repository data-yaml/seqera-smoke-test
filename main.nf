#!/usr/bin/env nextflow
/* groovylint-disable-next-line CompileStatic */
nextflow.enable.dsl = 2

process tiny_test {
    publishDir params.outdir, mode: 'copy'

    output:
    path 'test.txt'
    path 'system-info.txt'

    script:
    """
    echo 'Hello from Seqera Platform smoke test' > test.txt
    echo 'Test completed successfully at:' >> test.txt
    date >> test.txt

    echo 'System Information' > system-info.txt
    echo '==================' >> system-info.txt
    echo '' >> system-info.txt
    echo 'Hostname:' >> system-info.txt
    hostname >> system-info.txt
    echo '' >> system-info.txt
    echo 'Date:' >> system-info.txt
    date >> system-info.txt
    echo '' >> system-info.txt
    echo 'Working Directory:' >> system-info.txt
    pwd >> system-info.txt
    echo '' >> system-info.txt
    echo 'Disk Space:' >> system-info.txt
    df -h . >> system-info.txt
    """
}

workflow {
    tiny_test()

    tiny_test.out[0].view { file -> "Generated output: ${file}" }
}
