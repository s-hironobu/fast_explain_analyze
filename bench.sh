#!/bin/bash
#
#
#    Usage: $0 {setup|benchmark} [original|alt-wrapper|only-in-node]
#
# Copyright (c) 2025-2026, Hironobu Suzuki @ interdb.jp

set -eu -o pipefail

#--------------------
# Set Variables
#--------------------
BASE=`pwd`
SOURCE_DIR=${BASE}/postgres
PGSQL_DIR=${BASE}/pgsql
DB_NAME="testdb"

# Base branch: PostgreSQL master (development branch).
BRANCH="master"

# If you want to pin the base to a specific commit on master,
# set COMMIT to its hash.  If empty, the tip of origin/master
# fetched by 'setup' is used.  ('benchmark' does not fetch, so all
# phases are built on the same base.)
COMMIT=""

# Patches
PATCH_ALT_WRAPPER="v1-0001-alt-rowcount-only-instr-wrapper.patch"
PATCH_ONLY_IN_NODE="v1-0001-rowcount-only-instr-in-ExecProcNode.patch"

#--------------------
# Common
#--------------------
git_reset() {
    cd $SOURCE_DIR
    git reset --hard HEAD
    if [ $? -ne 0 ]; then
	echo "Error: Failed to execute 'git reset --hard HEAD'."
	exit 1
    fi
    local target=${COMMIT:-origin/$BRANCH}
    git checkout -B $BRANCH $target
    if [ $? -ne 0 ]; then
	echo "Error: Failed to execute 'git checkout -B $BRANCH $target'."
	exit 1
    fi
    git reset --hard $target
    if [ $? -ne 0 ]; then
	echo "Error: Failed to execute 'git reset --hard $target'."
	exit 1
    fi
    echo "Base: $BRANCH `git rev-parse HEAD`"
    cd $BASE
}

git_fetch() {
    cd $SOURCE_DIR
    git fetch origin $BRANCH:refs/remotes/origin/$BRANCH
    if [ $? -ne 0 ]; then
	echo "Error: Failed to fetch '$BRANCH'."
	exit 1
    fi
    cd $BASE
}

make_clean() {
    cd $SOURCE_DIR
    if [ -f $SOURCE_DIR/config.log ]; then
	make clean
	if [ $? -ne 0 ]; then
	    echo "Warning: Failed to execute 'make clean'."
	fi
    fi
}

#--------------------
# Setup
#--------------------

setup() {
    # 1. git clone postgres
    if ! git -v >/dev/null 2>&1; then
	echo "Error: git command not found." >&2
	exit 1
    fi

    if [ ! -d $SOURCE_DIR ]; then
	git clone -b $BRANCH https://github.com/postgres/postgres.git
	if [ $? -ne 0 ]; then
	    echo "Error: Failed to clone PostgreSQL repository."
	    exit 1
	fi
    fi

    # 2. git fetch master && git reset
    git_fetch
    git_reset

    # 3. configure && make && make install
    make_clean

    ./configure --prefix=$PGSQL_DIR --without-icu CFLAGS="-O3 -g"
    make -j4 && make install

    # 4. initdb
    cd $PGSQL_DIR

    if [ ! -d $PGSQL_DIR/data ]; then
	./bin/initdb -D data
	if [ $? -eq 0 ]; then
            echo "Database cluster created successfully."
	else
	    echo "Error: Failed to execute 'initdb'."
	    exit 1
	fi

	echo "include 'custom_settings.conf'" >> $PGSQL_DIR/data/postgresql.conf

	echo "shared_buffers = 512MB" > $PGSQL_DIR/data/custom_settings.conf
	echo "max_parallel_workers_per_gather = 0" >> $PGSQL_DIR/data/custom_settings.conf
	echo "max_parallel_workers = 0" >> $PGSQL_DIR/data/custom_settings.conf
	echo "parallel_leader_participation = off" >> $PGSQL_DIR/data/custom_settings.conf
    fi

    # 5. pg_ctl start
    cd $PGSQL_DIR
    if ./bin/psql -l >/dev/null 2>&1; then
	echo "==========================================="
	echo "Error: Other PostgreSQL is already running."
	echo "       Stop the server and try setup again."
	echo "==========================================="
	exit 1
    fi

    ./bin/pg_ctl -D data start
    if [ $? -ne 0 ]; then
	echo "Error: Failed to execute 'pg_ctl -D data start'."
	exit 1
    fi

    # 6. createdb
    cd $PGSQL_DIR
    if ./bin/psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
	echo "Database '$DB_NAME' already exists."
    else
	echo "Database '$DB_NAME' does not exist. Creating..."
	./bin/createdb "$DB_NAME"
	if [ $? -eq 0 ]; then
            echo "Database '$DB_NAME' created successfully."
	else
            echo "Error: Failed to create database '$DB_NAME'."
            exit 1
	fi
    fi

    # 7. create tables and indexes
    cd $PGSQL_DIR
    ./bin/psql -d $DB_NAME -c "DROP TABLE IF EXISTS test1, test2, test3;
    	CREATE TABLE test1 (id int, data int);
    	CREATE INDEX test1_id_idx ON test1 (id);
    	CREATE TABLE test2 (id int PRIMARY KEY, data int);
    	CREATE TABLE test3 (id int PRIMARY KEY, data int);
    	INSERT INTO test1 (id, data) SELECT i, i % 51  FROM generate_series(1, 150000) AS i;
    	INSERT INTO test1 (id, data) SELECT i, i % 51 FROM generate_series(1, 5000) AS i;
    	INSERT INTO test2 (id, data) SELECT i, floor(random() * 50 + 1)::int FROM generate_series(1, 50000) AS i;
    	INSERT INTO test3 (id, data) SELECT i, i FROM generate_series(1, 100000) AS i;
    	ANALYZE;"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create tables in '$DB_NAME'."
        exit 1
    fi

    ./bin/pg_ctl -D data stop

    echo "==========================="
    echo "Setup completed!"
    echo "==========================="
}

#--------------------
# benchmark
#--------------------

bench() {
    local title=$1
    local batch=$2
    local log=$3

    cd $PGSQL_DIR
    ./bin/pg_ctl -D data start
    echo "== $title =="
    ./bin/psql -d $DB_NAME -e -f ../batches/$batch 2>&1 | tee $log
    ./bin/pg_ctl -D data stop
}

run_benchmark_phase() {
    local phase_name=$1
    local patch_file=$2
    local batch_file=$3

    make_clean
    git_reset
    cd $SOURCE_DIR

    if [ -n "$patch_file" ]; then
        patch -p1 < "../patches/$patch_file"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to apply '$patch_file'."
            exit 1
        fi
    fi

    ./configure --prefix=$PGSQL_DIR --without-icu CFLAGS="-O3 -g"
    make -j4 && make install
    cd $PGSQL_DIR
    bench "$phase_name" "$batch_file" "${phase_name}.log"
}


original_bench() {
    run_benchmark_phase "original" "" "batch.sql"
}

alt_wrapper_bench() {
    run_benchmark_phase "alt-wrapper" "$PATCH_ALT_WRAPPER" "batch.sql"
}

only_in_node_bench() {
    run_benchmark_phase "only-in-node" "$PATCH_ONLY_IN_NODE" "batch.sql"
}


benchmark() {
    #
    # 1. check postgres repo
    #
    if [ ! -d $SOURCE_DIR ]; then
	echo "Error: PostgreSQL repository not found."
	exit 1
    fi

    #
    # 2. check data_dir
    #
    if [ ! -d $PGSQL_DIR ]; then
	echo "Error: $PGSQL_DIR not found."
	exit 1
    fi

    #
    # 3.  do benchmark
    #
    case "$1" in
	original)
	    echo "ORIGINAL"
	    original_bench
            ;;
	alt-wrapper)
	    echo "ALT-WRAPPER"
	    alt_wrapper_bench
            ;;
	only-in-node)
	    echo "ONLY-IN-NODE"
	    only_in_node_bench
            ;;
	ALL)
	    echo "ALL"
	    echo "ORIGINAL"
	    original_bench
	    echo "ALT-WRAPPER"
	    alt_wrapper_bench
	    echo "ONLY-IN-NODE"
	    only_in_node_bench
	    ;;
	*)
	    echo "Error: '$1' is not a valid argument."
	    exit 1
    esac
	    
    echo "==========================="
    echo "Benchmark completed!"
    echo "==========================="
}

#--------------------
# main
#--------------------

if [ $# -ne 1 ] && [ $# -ne 2 ]; then
    echo "Usage: $0 {setup|benchmark} [original|alt-wrapper|only-in-node]"
    exit 1
fi

PARAM="ALL"
if [ $# -eq 2 ]; then
    case "$2" in
	"original" | "alt-wrapper" | "only-in-node" )
	    PARAM=$2
	    ;;
	*)
	    echo "Usage: $0 {setup|benchmark} [original|alt-wrapper|only-in-node]"
	    exit 1
	    ;;
    esac
fi


case "$1" in
    setup)
        setup
        ;;
    benchmark)
	echo -n "Confirm that no other PostgreSQL server is active. Do you want to continue? [y/N]: "
	read answer
	cd $PGSQL_DIR
	if ./bin/psql -l >/dev/null 2>&1; then
	    echo "==========================================="
	    echo "Error: Other PostgreSQL is already running."
	    echo "       Stop the server and try benchmark again."
	    echo "==========================================="
	    exit 1
	fi

	case "$answer" in
	    y|Y|yes|Yes|YES)
		echo -n "This benchmark will take a few hours. Do you want to continue? [y/N]: "
		read answer

		case "$answer" in
		    y|Y|yes|Yes|YES)
			echo "Continuing..."
			benchmark $PARAM
			;;
		    *)
			echo "Exiting."
			exit 1
			;;
		esac
		;;
	    *)
		echo "Exiting."
		exit 1
		;;
	esac
        ;;
    help)
	echo "Usage: $0 {setup|benchmark} [original|alt-wrapper|only-in-node]"
	;;
    *)
        echo "Error: Invalid argument. Use 'setup' or 'benchmark'."
        exit 1
        ;;
esac
