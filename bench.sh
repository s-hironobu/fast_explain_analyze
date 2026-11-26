#!/bin/bash
#
#
#    Usage: $0 {setup|benchmark [all|variant]}
#
#      setup                 build PostgreSQL 20devel and create the database
#      benchmark             original, alt-wrapper
#      benchmark all         original, alt-wrapper, only-in-node (experimental)
#      benchmark <variant>   only the given variant
#
#      variants:
#        original               unpatched
#        alt-wrapper            row counting in a lightweight wrapper
#        only-in-node           (experimental) counting in ExecProcNode()
#
#      Base: PostgreSQL 20devel, commit 9ebc9a458c3 (COMMIT_PG20).
#      Install directory: ./pgsql-pg20
#
#    Older bases (not documented in README.md; kept for reference):
#      -b|--base master   tip of origin/master (or COMMIT_MASTER), ./pgsql
#                           variants: original alt-wrapper only-in-node
#      -b|--base pg19     47a9f61 (the base of Phase 3 in version 1.0), ./pgsql-pg19
#                           variants: original phase-2 phase-3 alt-wrapper
#                                     only-in-node
#      Each base has its own install directory and database cluster.
#
# Copyright (c) 2025-2026, Hironobu Suzuki @ interdb.jp

set -eu -o pipefail

#--------------------
# Set Variables
#--------------------
BASE=`pwd`
SOURCE_DIR=${BASE}/postgres
DB_NAME="testdb"

# Base branch: PostgreSQL master (development branch).
BRANCH="master"

# --base pg20 (default): PostgreSQL 20devel.
#   The commit the patches in patches/pg20-*.patch were made and tested on.
#   All variants are built on it.
COMMIT_PG20="9ebc9a458c3"

# --base master (legacy):
#   If you want to pin the base to a specific commit on master,
#   set COMMIT_MASTER to its hash.  If empty, the tip of origin/master
#   fetched by 'setup' is used.
COMMIT_MASTER=""

# --base pg19 (legacy):
#   The commit on which Phase 3 was benchmarked in version 1.0.
COMMIT_PG19="47a9f61fcafcf26bd3d68740ca05ba69ac729d93"

# Set by select_base()
BASE_SET=""
COMMIT=""
PGSQL_DIR=""
DEFAULT_VARIANTS=""	# 'benchmark'
ALL_VARIANTS=""		# 'benchmark all'

select_base() {
    BASE_SET=$1
    case "$BASE_SET" in
	pg20)
	    COMMIT=$COMMIT_PG20
	    PGSQL_DIR=${BASE}/pgsql-pg20
	    DEFAULT_VARIANTS="original alt-wrapper"
	    ALL_VARIANTS="original alt-wrapper only-in-node"
	    ;;
	master)
	    COMMIT=$COMMIT_MASTER
	    PGSQL_DIR=${BASE}/pgsql
	    DEFAULT_VARIANTS="original alt-wrapper"
	    ALL_VARIANTS="original alt-wrapper only-in-node"
	    ;;
	pg19)
	    COMMIT=$COMMIT_PG19
	    PGSQL_DIR=${BASE}/pgsql-pg19
	    DEFAULT_VARIANTS="original alt-wrapper"
	    ALL_VARIANTS="original phase-2 phase-3 alt-wrapper only-in-node"
	    ;;
	*)
	    echo "Error: unknown base '$BASE_SET'."
	    exit 1
	    ;;
    esac
}

# Return the patch file for a variant of the selected base ("" = none).
variant_patch() {
    case "$BASE_SET:$1" in
	*:original)                    echo "" ;;
	pg20:alt-wrapper)              echo "pg20-alt-wrapper.patch" ;;
	pg20:only-in-node)             echo "pg20-only-in-node.patch" ;;
	master:alt-wrapper)            echo "v1-0001-alt-rowcount-only-instr-wrapper.patch" ;;
	master:only-in-node)           echo "v1-0001-rowcount-only-instr-in-ExecProcNode.patch" ;;
	pg19:phase-2)                  echo "pg19-phase-2.patch" ;;
	pg19:phase-3)                  echo "pg19-phase-3.patch" ;;
	pg19:alt-wrapper)              echo "pg19-alt-wrapper.patch" ;;
	pg19:only-in-node)             echo "pg19-only-in-node.patch" ;;
	*)
	    echo "Error: '$1' is not a valid variant for base '$BASE_SET'." >&2
	    echo "       Valid variants: $ALL_VARIANTS" >&2
	    exit 1
	    ;;
    esac
}

usage() {
    echo "Usage: $0 setup"
    echo "       $0 benchmark                # original, alt-wrapper"
    echo "       $0 benchmark all            # + only-in-node (experimental)"
    echo "       $0 benchmark <variant>      # only the given variant"
    echo "  variants: original alt-wrapper only-in-node"
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
    echo "Base ($BASE_SET): `git rev-parse HEAD`"
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
    #    (clean first: the tree may still be configured for the other base)
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
    echo "Setup completed! (base: $BASE_SET, $PGSQL_DIR)"
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

    echo "Building '$variant' (base: $BASE_SET) ..."
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
    echo "== round $round: $variant ($BASE_SET) =="
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
	echo "Error: $PGSQL_DIR/data not found.  Run: $0 --base $BASE_SET setup"
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

BASE_OPT="pg20"
if [ $# -ge 1 ]; then
    case "$1" in
	-b|--base)
	    if [ $# -lt 2 ]; then
		usage
		exit 1
	    fi
	    BASE_OPT=$2
	    shift 2
	    ;;
	--base=*)
	    BASE_OPT=${1#--base=}
	    shift
	    ;;
    esac
fi
select_base "$BASE_OPT"

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
	    echo "Error: $PGSQL_DIR not set up.  Run: $0 --base $BASE_SET setup"
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
