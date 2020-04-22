#!/bin/bash

# Generate parquet files with
# DataTypes int32, int64, str
# Encodings plain & delta for ints, deltalen for str
# Varying page sizes at 1 GB total data size

fulldatasize=$((10**9)) #1 GBytes of data
outdir=/data/parquetfiles/new
parquetwriter=~/workspaces/openCAPI/fast-p2a/software/cpp/test/parquetwriter_test

rm *.prq
mkdir $outdir

for datatype in int32 int64 str; do
	if [ "$datatype" == "int32" ]; then
		entrysize=4
	elif [ "$datatype" == "int64" ]; then
		entrysize=8
	else
		entrysize=64
	fi
    fullsize_entries=$((fulldatasize/entrysize))
	$parquetwriter $datatype $fullsize_entries 1
	for exp in $(seq 3 9); do
		size_bytes=$((10**exp))
        size_entries=$((size_bytes/entrysize))
		echo "Generating $datatype files of size $fulldatasize bytes and pagesize $size_bytes bytes ($size_entries entries)"
		echo "./run.sh test_${datatype}.prq test_${datatype}_ps${size_bytes}_plain.prq $size_entries plain"
		echo "./run.sh test_${datatype}.prq test_${datatype}_ps${size_bytes}_delta.prq $size_entries delta"
		./run.sh test_${datatype}.prq test_${datatype}_ps${size_bytes}_plain.prq $size_entries plain
		mv test_${datatype}_ps${size_bytes}_plain.prq $outdir
		if [ $datatype != "str" ]; then
			./run.sh test_${datatype}.prq test_${datatype}_ps${size_bytes}_delta.prq $size_entries delta
			mv test_${datatype}_ps${size_bytes}_delta.prq $outdir
		fi
	done
	if [ "$datatype" == "str" ]; then
		mv test_str.prq $outdir #needed for str, because the cpp lib only supports plain encoding
	else
		ln -sf test_${datatype}_ps1000_plain.prq $outdir/test_${datatype}.prq
	fi
done



