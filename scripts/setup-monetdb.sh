#!/bin/bash
#
# setup-monetdb
#
# A script for setting up a DB with MonetDB containing the TPC-H, JCC-H and IMDB_JOB schema
# and generated data set (with user-specified scale factor). Must be run
# after MonetDB itself has been properly installed and is available in the
# executable search path
#
#################################################################################
# By Eyal Rozenberg <eyalroz@technion.ac.il>
#################################################################################
# Edit by Pei Mu <ds1231h@gmail.com>
#################################################################################
#

#------------------------------
# Helper functions

function usage {
	REPOSITORY_URL="https://github.com/PeiMu/tpch-monet"
	echo "Usage: $0 [OPTIONS...]"
	echo "Downloads, build and installs MonetDB and the dbgen utlilities; generates TPC-H, JCC-H and JOB"
	echo "data, creates a DB farm, creates a DB and loads the data there."
	echo
	echo "Options:"
	echo "  -r, --recreate              If the database exists, recreate it, dropping"
	echo "                              all existing data. (If this option is unset, the "
	echo "                              database must not already exist)"
	echo "  -s, --scale-factor FACTOR   The amount of test data to generate, in GB"
	echo "  -G, --use-generated         Use previously-generated table load files (in the"
	echo "                              data generation directory instead of re-generating"
	echo "                              them using the dbgen utility."
	echo "  -l, --log-file FILENAME     Name of the file to log output into"
	echo "  -d, --db-name NAME          Name of the database holding test data"
	echo "                              within the DB farm"
	echo "  -f, --db-farm PATH          Filesystem path for the root directory of the DB farm"
	echo "                              with the generated DB"
	echo "  -p, --platform              Platform for which to try building the data "
	echo "                              generation utility (one of ATT DOS HP IBM ICL MVS SGI"
	echo "                              SUN U2200 VMS LINUX WIN32 MAC)"
	echo "  -P, --port NUMBER           Network port on the local host, which the server"
	echo "                              will related to the DB farm"
	echo "  -D, --data-gen-dir PATH     directory in which to generate the table data"
	echo "  -k, --keep-raw-tables       Keep the raw data generated by the tool outside of"
	echo "                              the DBMS"
	echo "  -v, --verbose               Be verbose"
	echo "	-b, --benchmark BENCHMAKR   Name of the benchmark, e.g. TPC-H, JCC-H, JOB, etc."
	echo
	echo "For more information, for feedback and for bug reports - please visit this tool's"
	echo "source repository online at $REPOSITORY_URL ."
}


function die {
	echo -e "$1" >&2   # error message to stderr
	exit ${2:-1}  # default exit code is -1 but you can specify something else
}

function gb_available_space_for_dir {
	# Note this returns the number of 2^30 bytes, not 10^9
	 df --block-size=G --output=avail $1 | tail -1 | grep -o "[0-9]*"
}

function is_positive_int {
	[[ $1 =~ ^[0-9]+$ ]] && [[ ! $1 =~ ^0+$ ]]
}

# (monetdb's command-line utilities are not so great
# at reporting the status of things in machine-readable format)

function db_farm_exists {
	[[ $(monetdbd get all $1 2>/dev/null | wc -l)  -ne 0 ]]
}

function property_of_dbfarm {
	local property_name="$1"
	local db_farm="$2"
	monetdbd get $property_name $db_farm | tail -1 | sed "s/$property_name *//;"
}

function db_farm_is_up {
	db_farm="$1"
	# When a DB farm is up, the status is "monetdbd[process num here] version here (release name here) is serving this dbfarm";
	# when it's down, the status is "no monetdbd is serving this dbfarm"
	[[ $(property_of_dbfarm status $1) =~ "monetdbd[" ]]
}

function db_is_up {
	# This assumes the DB exists
	local db_name=$1
	[[ "$be_verbose" ]] && echo monetdb -p $port status $db_name 2>/dev/null
	status=$(monetdb -p $port status $db_name 2>/dev/null | tail -1 | sed -r 's/^'$db_name'\s*([^ ]*).*$/\1/;')
	[[ "$be_verbose" ]] && echo "Database $db_name is" $(echo $status | sed 's/R/running/; s/S/not running/; s/^$/not running/')
	[[ -n "$status" && $status == "R" ]] && return 0 || return 1
}

function db_exists {
	local db_name=$1
	local port=$2
	[[ $(monetdb -p $port status $db_name 2>/dev/null | wc -l) > 0 ]]
}

function run_mclient {
	local language="sql"
	local queries="$1"
	local format="${2:-csv}"
	[[ $be_verbose ]] && echo "mclient -lsql -f $format -d $db_name -p $port -s \"\$queries\""
	mclient -lsql -f $format -d $db_name -p $port -s "$queries"
}

function dbgen_is_valid {
	[[ -n $($dbgen_binary -h 2>&1 | head -1 | grep "TPC-H Population Generator") ]]
}

function is_in_list {
	local needle="$1"
	shift
	for haystack_item in $@; do
		[[ "$needle" == "$haystack_item" ]] && found=1
	done
	[[ -n "$found" ]]
}

# This is a rather lame hack, but it seems to work for
# Windows, Linux and MacOS. Note we're returning WIN32
# even if it's 64-bit windows - for compatibility
# with the TPC-H dbgen sources
function get_platform {
	if [ "$(uname)" == "Darwin" ]; then echo "MAC"
	elif [ "$(expr substr $(uname -s) 1 5)" == "Linux" ]; then echo "LINUX"
	elif [ "$(expr substr $(uname -s) 1 10)" == "MINGW32_NT" ]; then echo "WIN32"
	elif [ "$(expr substr $(uname -s) 1 10)" == "MINGW64_NT" ]; then echo "WIN32"
	fi
}

#------------------------------

TODAY=$(date +%Y-%m-%d)

# Default parameter values here...

scale_factor=1
directory_of_script="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
dbgen_dir="${directory_of_script}/../dbgen"
data_generation_dir="${PWD}/tpch_generated_tables_${TODAY}"
log_file="${0}.log"
keep_raw_tables=
port=50000
benchmark=TPC-H

#------------------------------
# Parse command line here
#
while [[ $# > 0 ]]; do
	option_key="$1"
	
	case $option_key in
	-v|--verbose)
		be_verbose=1
		;;
	-r|--recreate)
		recreate_db=1
		;;
	-p|--platform|--machine|--os)
		platform="$2"
		is_in_list $platform ATT DOS HP IBM ICL MVS SGI SUN U2200 VMS LINUX WIN32 MAC || die "Invalid platform"
		shift # past argument
		;;
	-s|--scale-factor|--sf)
		scale_factor="$2"
		is_positive_int $scale_factor || die "Invalid scale factor $scale_factor"
		shift # past argument
		;;
	-g|--dbgen-dir)
		raw_dbgen_dir="$2"
		dbgen_dir=${raw_dbgen_dir%%/}
		shift # past argument
		;;
	-G|--use-generated|--data-already-generated|--already-generated|--have-generated-data|--have-generated)
		already_generated=1
		;;
	-d|--dbname|--db-name|--database-name)
		db_name="$2"
		shift # past argument
		;;
	-l|--log-file)
		log_file="$2"
		shift # past argument
		;;
	-f|--farm|--db-farm|--dbfarm|--database-farm)
		db_farm="$2"
		shift # past argument
		;;
	-P|--port|--dbfarm-port)
		port="$2"
		shift # past argument
		is_positive_int $port || die "Invalid DB farm port $port"
		;;
	-D|--data-gen-dir|--data-generation-directory|--data-generation-dir|--gen-dir|--data-gen-directory)
		raw_data_generation_dir="$2"
		data_generation_dir="$(readlink -f $raw_data_generation_dir)"
		shift # past argument
		;;
	-k|--keep-raw-tables|--keep-raw)
		keep_raw_tables=1
		;;
	-b|--benchmark)
		benchmark="$2"
		shift # past argument
                ;;
	*) # unknown option
		echo "Unknown command line option $option_key" 1>&2
		break
		;;
	esac
	shift # past argument or value
done
if [[ $# > 0 ]]; then
	usage
	exit -1
fi

[[ -n "$db_farm" ]] || db_farm="$DB_FARM"
[[ -n "$db_farm" ]] || db_farm="$HOME/db_farms/monetdb"
[[ -n "$db_name" ]] || db_name="tpch-sf-$scale_factor"
[[ -n "$platform" ]] || platform="$(get_platform)"
#
#------------------------------

# This makes sure both the console and the log file get both stderr and stdout
exec >& >(tee $log_file)

# Derived non-user-controlled parameters

if [[ -n "$already_generated" ]]; then
	[[ -d "$data_generation_dir" ]] || die "Was requested to use already-generated data, but the directory for it is missing: ${data_generation_dir}"
fi

if [[ -z "$already_generated" ]]; then
	if [[ -z $dbgen_binary ]] || [[ -z $dbgen_dists_file ]] ; then
		if [[ -z $dbgen_dir ]]; then
			echo "Could not locate the TPC dbgen tool directory/binary & dists file" >&2
			echo "(you did not specify their location using -g)"
			echo "If you don't have them - they may be obtained from from http://www.tpc.org/tpch" >&2
			exit -1
		fi
	fi
	[[ -n $dbgen_dists_file ]] || dbgen_dists_file=$dbgen_dir/dists.dss
	[[ -n $dbgen_binary ]] || dbgen_binary=$dbgen_dir/dbgen
	if [[ ! -f $dbgen_dists_file ]]; then
		echo -e "Cannot find the distributions file $dbgen_dists_file used by the test data generator.\nDid you remember to pull/clone the dbgen submodule? If not, try 'git submodule update --init dbgen/'" >&2
		exit -1
	fi
	if [[ ! -r $dbgen_dists_file ]]; then
		echo "The distributions file $dbgen_dists_file used by the test data generator is not readable." >&2
		exit -1
	fi
	if [[ ! -f $dbgen_binary ]]; then
		[[ -n "$platform" ]] || die "Cannot determine the platform parameter necessary for building the TPC-H dbgen utility. You must specify it explicitly."
		dbgen_binary="${dbgen_dir}/dbgen" # we'll build this...
		if [[ ! -r $dbgen_dir/Makefile ]]; then
			if [[ -r $dbgen_dir/CMakeLists.txt ]]; then
				pushd $dbgen_dir
				type cmake 1>/dev/null || die "CMake build tool unavailable"
				cmake -DMACHINE=$platform -DDATABASE=VECTORWISE . || die "Failure building the generation utility in $dbgen_dir - during CMake"
				popd
			else
				if [[ -f $dbgen_dir/makefile.suite ]]; then
					sed 's/^WORKLOAD = /WORKLOAD=TPCH/; s/^MACHINE = /MACHINE='"$platform"'/; s/DATABASE=/DATABASE=VECTORWISE/;' $dbgen_dir/makefile.suite > $dbgen_dir/Makefile
				fi
			fi
		fi
		[[ -f $dbgen_dir/Makefile ]] || die "Could not find or generate a Makefile in $dbgen_dir for building the generator utility $dbgen_binary"
		type make 1>/dev/null || die "GNU Make unavailable"
		make -C $dbgen_dir || die "Failure building the generation utility in $dbgen_dir - Make failure"
		[[ -f $dbgen_binary ]] || die "Although the build of $dbgen_binary has supposedly succeeded - the binary is missing."
	fi
	[[ -f $dbgen_binary ]] || die "Cannot find the dbgen data generation binary at $dbgen_binary"
	[[ -x $dbgen_binary ]] || die "The generation utility $dbgen_binary is not an executable file."
fi

# Note: We don't really need that extra space, but... better be on the safe side (especially if the .tbl directory and the DB farm are on the same partition)
necessary_space_in_gb=$(( 2 * $scale_factor ))

# Check for binaries

if [[ -z "$already_generated" ]]; then
	[[ -x $dbgen_binary ]] || die "Cannot locate the TPC-H data generation utility"
	[[ -r $dbgen_dists_file ]] || die "Cannot locate the dists.dss file for the TPC-H data generation utility; get the entire utility at http://www.tpc.org/tpch/"
	dbgen_binary=$(readlink -f $dbgen_binary )
	dbgen_dists_file=$(readlink -f $dbgen_dists_file )
	dbgen_is_valid || die "Invalid TPC-H data generator binary $dbgen_binary; get it at http://www.tpc.org/tpch/"
fi

for binary in monetdb monetdbd; do
	[[ -n `which $binary` ]] || die "Missing MonetDB binary $binary"
done

if [[ -z "$already_generated" ]]; then
	[[ ! -d $data_generation_dir ]] || die "The intended data generation directory $data_generation_dir is already present.\nYou must either remove it, use a subdirectory within it, or invoke this script with the --use-generated option to use the data in it."
	[[ ! -e $data_generation_dir ]] || die "The intended data generation directory $data_generation_dir is already present, but as a non-directory; please remove it or specify a different directory."
	mkdir -p "$data_generation_dir" || die "Failed creating the generation directory for TPC-H data: ${data_generation_dir}"
	(( $(gb_available_space_for_dir $data_generation_dir) > $necessary_space_in_gb )) ||
	die "Not enough disk space on the device holding $data_generation_dir to generate the TPC-H data: We need ${necessary_space_in_gb} GiB but only have $(gb_available_space_for_dir $data_generation_dir) GiB."
fi

# Avoid the annoying password prompt if possible...
[[ -r "$HOME/.monetdb" ]] || echo -e "user=monetdb\npassword=monetdb\nlanguage=sql\n" > $HOME/.monetdb

# Ensure we have a DB farm that's up in which to create the TPC-H DB - or try to create it

if db_farm_exists $db_farm; then
	port=$(property_of_dbfarm "port" $db_farm)
	db_farm_is_up $db_farm || monetdbd start $db_farm || die "Could not start the DB farm at $db_farm"
else
	[[ -d $db_farm ]] || mkdir -p $db_farm || die "Failed creating a directory for the DB farm at $db_farm"
	[[ "$be_verbose" ]] && echo "monetdbd create $db_farm"
	monetdbd create $db_farm || die "A MonetDB database farm does not exist at ${db_farm}, and cannot be created there."
	[[ "$be_verbose" ]] && echo "monetdbd set port=$port $db_farm"
	monetdbd set port=$port $db_farm || die "Can't set the daemon port for new DB farm ${db_farm} to ${port}."
	[[ "$be_verbose" ]] && echo "monetdbd start $db_farm"
	monetdbd start $db_farm || die
fi

db_farm_is_up $db_farm || die "Could not get DB farm at $db_farm to the started state"

if db_exists "$db_name" "$port"; then
	if db_is_up "$db_name" "$port"; then
		[[ "$be_verbose" ]] &&  echo "monetdb -p $port stop $db_name"
		monetdb -p $port stop $db_name  >/dev/null || die "Can't stop the existing DB named $db_name in DB farm $db_farm."
	fi
	if [[ "$recreate_db" ]]; then
		[[ "$be_verbose" ]] &&  echo "monetdb -p $port destroy -f $db_name"
		monetdb -p $port destroy -f $db_name >/dev/null || die "Failed destroying the existing DB named $db_name in DB farm $db_farm."
		need_to_create_the_db=1
	else
		die "A database named $db_name already exists in DB farm ${db_farm}, so giving up. Perhaps you wanted to recreate it?"
	fi
else
	need_to_create_the_db=1
fi

(( $(gb_available_space_for_dir $db_farm) > $necessary_space_in_gb )) ||
die "Not enough disk space at $db_farm to generate the TPC-H data: We need ${necessary_space_in_gb} GiB but have $(gb_available_space_for_dir $db_farm) GiB."

# Create the DB and SQL-create its schema

if [[ "$need_to_create_the_db" ]]; then
	[[ "$be_verbose" ]] && echo "Creating the empty database $db_name in DB farm $db_farm"
	(
		( [[ "$be_verbose" ]] && echo "monetdb -p $port create $db_name" ; monetdb -p $port create $db_name > /dev/null ) &&
		( [[ "$be_verbose" ]] && echo "monetdb -p $port release $db_name" ;  monetdb -p $port release $db_name > /dev/null )
	) || die "Failed to create (and release) a database named $db_name in DB farm $db_farm"
	[[ "$be_verbose" ]] && echo "Populating the schema of database $db_name"
	if [[ "$benchmark" = "TPC-H" ]]; then
		create_without_constraints=$(cat tpch_setup/create_without_constraints.sql)
		echo "$create_without_constraints"
		run_mclient "$create_without_constraints"
		add_key_constraints=$(cat tpch_setup/add_key_constraints.sql)
		echo "$add_key_constraints"
		run_mclient "$add_key_constraints"
	elif [[ "$benchmark" = "JCC-H" ]]; then
		create_without_constraints=$(cat jcch_setup/create_without_constraints.sql)
		echo "$create_without_constraints"
		run_mclient "$create_without_constraints"
		add_key_constraints=$(cat jcch_setup/add_key_constraints.sql)
		echo "$add_key_constraints"
		run_mclient "$add_key_constraints"
	elif [[ "$benchmark" = "JOB" ]]; then
		create_without_constraints=$(cat imdb_setup/create_without_constraints.sql)
		echo "$create_without_constraints"
		run_mclient "$create_without_constraints"
                add_index=$(cat imdb_setup/add_index.sql)
                echo "$add_index"
                run_mclient "$add_index"
	fi
fi

# Generate the TPC-H data

if [[ "$benchmark" = "TPC-H" ]]; then
	if [[ -z "$already_generated" ]] ; then
	pushd $data_generation_dir >/dev/null
	
		[[ "$be_verbose" ]] && dbgen_verbosity_option="-v"
		[[ "$be_verbose" ]] && echo "$dbgen_binary -v -b $dbgen_dists_file -s $scale_factor"
		$dbgen_binary -b $dbgen_dists_file -s $scale_factor $dbgen_verbosity_option || die "Failed generating TPC-H data using $dbgen_binary with scale factor $scale_factor, at $data_generation_dir"
		popd >&/dev/null
	else
		[[ -d $data_generation_dir ]] || die "Pre-generated data directory $data_generation_dir is missing"
	fi
fi

# Data generation is complete, time to load it
if [[ "$benchmark" = "TPC-H" ]]; then
	for table_name in region nation supplier customer part partsupp orders lineitem; do
		table_file="$data_generation_dir/${table_name}.tbl"
		[[ -r $table_file ]] || die "Could not find the generated data file ${table_file} - perhaps its generation failed?"
	done
fi

[[ "$be_verbose" ]] && echo "Loading generated data from $data_generation_dir"
output_format=$( [[ "$be_verbose" ]] && echo "csv" || echo "trash" )

if [[ "$benchmark" = "TPC-H" ]]; then
	load_data=$(cat tpch_setup/load_data.sql)
	echo "$load_data"
	run_mclient "$load_data" $output_format
elif [[ "$benchmark" = "JCC-H" ]]; then
	load_data=$(cat jcch_setup/load_data.sql)
	echo "$load_data"
	run_mclient "$load_data" $output_format
elif [[ "$benchmark" = "JOB"  ]]; then
	load_data=$(cat imdb_setup/load_data.sql)
        echo "$load_data" 
        run_mclient "$load_data" $output_format
fi

[[ -n "$keep_raw_tables" ]] || rm -r $data_generation_dir
