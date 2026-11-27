#!/bin/bash
#
#    Usage: $0 {setup|benchmark [all|variant]}
#
#      setup                 build PostgreSQL 20devel and create the database
#      benchmark             original, lite-rowcount
#      benchmark all         original, lite-rowcount, feather-rowcount
#      benchmark <variant>   only the given variant
#
#      variants:
#        original          unpatched
#        lite-rowcount     row counting in a lightweight wrapper
#        feather-rowcount  (experimental) row counting inlined in ExecProcNode()
#
#      Base: PostgreSQL 20devel, commit 9ebc9a458c3 (COMMIT).
#      Install directory: ./pgsql-pg20
#
#    Note: Versions 2.5 and older of this tool also supported the bases
#    "master" and "pg19" (47a9f61) with the Phase 2/3 patches of the first
#    post.  They were removed in version 2.6; see the git history.
#
# Copyright (c) 2025-2026, Hironobu Suzuki @ interdb.jp

set -eu -o pipefail

#--------------------
# Set Variables
#--------------------
BASE=`pwd`
SOURCE_DIR=${BASE}/postgres
PGSQL_DIR=${BASE}/pgsql-pg20
DB_NAME="testdb"

# Base: PostgreSQL 20devel (master).
# The commit the patches in patches/ were made and tested on.
# All variants are built on it.
BRANCH="master"
COMMIT="9ebc9a458c3"

DEFAULT_VARIANTS="original lite-rowcount"
ALL_VARIANTS="original lite-rowcount feather-rowcount"

# Return the patch file for a variant ("" = none).
variant_patch() {
    case "$1" in
	original)          echo "" ;;
	lite-rowcount)     echo "pg20-lite-rowcount.patch" ;;
	feather-rowcount)  echo "pg20-feather-rowcount.patch" ;;
	*)
	    echo "Error: '$1' is not a valid variant." >&2
	    echo "       Valid variants: $ALL_VARIANTS" >&2
	    exit 1
	    ;;
    esac
}

usage() {
    echo "Usage: $0 setup"
    echo "       $0 benchmark                # original, lite-rowcount"
    echo "       $0 benchmark all            # + feather-rowcount (experimental)"
    echo "       $0 benchmark <variant>      # only the given variant"
    echo "  variants: original lite-rowcount feather-rowcount"
}

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
    local target=$COMMIT
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
    echo "Base: `git rev-parse HEAD`"
    git rev-parse HEAD > $PGSQL_DIR/BASE_COMMIT 2>/dev/null || true
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
    make_clean
    git_fetch
    mkdir -p $PGSQL_DIR
    git_reset

    # 3. configure && make && make install
    cd $SOURCE_DIR
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
    ./bin/psql -d $DB_NAME -c "VACUUM ANALYZE;"

    ./bin/pg_ctl -D data stop

    echo "==========================="
    echo "Setup completed! ($PGSQL_DIR)"
    echo "==========================="
}

#--------------------
# benchmark
#--------------------

# Number of rounds.  Override with e.g.  ROUNDS=5 bash ./bench.sh benchmark
ROUNDS=${ROUNDS:-3}

# Build one variant into its own install directory ($PGSQL_DIR/variants/<v>).
# An already built variant is reused; set REBUILD=1 to build it again.
build_variant() {
    local variant=$1
    local patch_file
    local prefix=$PGSQL_DIR/variants/$variant

    patch_file=$(variant_patch "$variant")
    if [ -x $prefix/bin/postgres ] && [ -z "${REBUILD:-}" ]; then
	echo "Variant '$variant' already built: $prefix  (REBUILD=1 to rebuild)"
	return
    fi

    echo "Building '$variant' ..."
    make_clean
    git_reset
    cd $SOURCE_DIR

    if [ -n "$patch_file" ]; then
	patch -p1 --no-backup-if-mismatch < "../patches/$patch_file"
	if [ $? -ne 0 ]; then
	    echo "Error: Failed to apply '$patch_file'."
	    exit 1
	fi
    fi

    ./configure --prefix=$prefix --without-icu CFLAGS="-O3 -g"
    make -j4 && make install
    if [ $? -ne 0 ] || [ ! -x $prefix/bin/postgres ]; then
	echo "Error: Failed to build '$variant'."
	exit 1
    fi
    cd $BASE
}

# Run batch.sql once with the given variant's server on the shared data dir.
run_once() {
    local variant=$1
    local round=$2
    local bin=$PGSQL_DIR/variants/$variant/bin
    local log=$PGSQL_DIR/rounds/$variant.r$round.log

    cd $PGSQL_DIR
    $bin/pg_ctl -D data -l data/server.log -w start
    echo "== round $round: $variant =="
    $bin/psql -d $DB_NAME -e -f $BASE/batches/batch.sql 2>&1 | tee $log
    $bin/pg_ctl -D data -w stop
}

benchmark() {
    #
    # 1. check postgres repo and the data dir
    #
    if [ ! -d $SOURCE_DIR ]; then
	echo "Error: PostgreSQL repository not found."
	exit 1
    fi
    if [ ! -d $PGSQL_DIR/data ]; then
	echo "Error: $PGSQL_DIR/data not found.  Run: $0 setup"
	exit 1
    fi

    local list
    case "$1" in
	DEFAULT) list="$DEFAULT_VARIANTS" ;;
	ALL)     list="$ALL_VARIANTS" ;;
	*)       list="$1" ;;
    esac

    #
    # 2. build every variant once, each into its own directory
    #
    for v in $list; do
	build_variant $v
    done

    #
    # 3. run in rounds.  The order of the variants is rotated in every round,
    #    so that no variant is always first (or last) and a slow drift of the
    #    machine does not end up in one variant.
    #
    mkdir -p $PGSQL_DIR/rounds
    set -- $list
    local n=$#
    local variants=("$@")

    # same heap state (hint bits, freeze) for everybody
    local first=${variants[0]}
    $PGSQL_DIR/variants/$first/bin/pg_ctl -D $PGSQL_DIR/data -l $PGSQL_DIR/data/server.log -w start
    $PGSQL_DIR/variants/$first/bin/psql -d $DB_NAME -c "VACUUM ANALYZE;"
    $PGSQL_DIR/variants/$first/bin/pg_ctl -D $PGSQL_DIR/data -w stop

    echo "Variants: $list   rounds: $ROUNDS"
    local r i idx
    for r in $(seq 1 $ROUNDS); do
	for i in $(seq 0 $((n - 1))); do
	    idx=$(( (i + r - 1) % n ))
	    run_once ${variants[$idx]} $r
	done
    done

    echo "==========================="
    echo "Benchmark completed!  Run: python3 ./analyze.py"
    echo "==========================="
}

#--------------------
# main
#--------------------

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    usage
    exit 1
fi

# benchmark [all|variant]
PARAM="DEFAULT"
if [ $# -eq 2 ]; then
    case "$2" in
	all|ALL|All) PARAM="ALL" ;;
	*)
	    variant_patch "$2" >/dev/null
	    PARAM=$2
	    ;;
    esac
fi


case "$1" in
    setup)
        setup
        ;;
    benchmark)
	if [ ! -x $PGSQL_DIR/bin/psql ]; then
	    echo "Error: $PGSQL_DIR not set up.  Run: $0 setup"
	    exit 1
	fi
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
	usage
	;;
    *)
        echo "Error: Invalid argument."
        usage
        exit 1
        ;;
esac
