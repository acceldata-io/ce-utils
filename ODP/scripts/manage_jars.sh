#!/bin/bash
# Acceldata Inc.

# Define variables
DIR="/usr/"
BACKUPDIR="/tmp/jar_backup"
JAR_FILES=("log4j-1.2.16.jar" "log4j-1.2.17.jar")
REPLACEMENT_JAR="/root/reload4j-1.2.19.jar"
DRY_RUN=true  # Default to true for dry-run mode
LOGFILE="/tmp/jar_backup_script.log"
METADATA_FILE="$BACKUPDIR/metadata.txt"

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
RESET='\033[0m'

# Function to log messages
log_message() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" >> "$LOGFILE"
}

# Function to print messages in color
print_info() {
    echo -e "${BLUE}[INFO]${RESET} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${RESET} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${RESET} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${RESET} $1"
}

print_dry_run() {
    echo -e "${MAGENTA}[DRY-RUN]${RESET} $1"
}

# Function to print actions without executing them
echo_action() {
    if $DRY_RUN; then
        print_dry_run "$1"
    else
        eval "$1"
    fi
}

# Function to ensure the metadata file exists
ensure_metadata_file() {
    if [ ! -f "$METADATA_FILE" ]; then
        echo_action "touch \"$METADATA_FILE\""
        log_message "Created metadata file at $METADATA_FILE"
    fi
}

# Print file details in a formatted way
print_file_details() {
    print_info "File backed up:"
    print_info "          Source: $1"
    print_info "          Target: $2"
    print_info "          Permissions: $3"
    print_info "          Ownership: $4"
}

# Backup function
backup_jars() {
    print_info "Starting backup process..."
    log_message "Starting backup process..."

    # Check if source directory exists
    if [ ! -d "$DIR" ]; then
        print_error "Source directory $DIR does not exist."
        log_message "Source directory $DIR does not exist."
        exit 1
    fi

    # Create backup directory if it doesn't exist
    echo_action "mkdir -p \"$BACKUPDIR/usr\""

    # Ensure metadata file exists
    ensure_metadata_file

    # Find and backup the specified JAR files
    for JAR in "${JAR_FILES[@]}"; do
        find "$DIR" -type f -name "$JAR" | while read -r FILE; do
            # Skip the specific file you don't want to back up
            if [[ "$FILE" == "/usr/lib/ambari-server/log4j-1.2.17.jar" ]]; then
                print_warning "Skipping backup of $FILE"
                continue
            fi

            # Prepare the backup path
            BACKUP_PATH="$BACKUPDIR/usr${FILE#/usr}"

            # Create the directory structure in the backup location
            echo_action "mkdir -p \"$(dirname "$BACKUP_PATH")\""

            # Store the permissions and ownership
            PERMISSIONS=$(stat -c "%a" "$FILE")
            OWNER=$(stat -c "%U:%G" "$FILE")

            # Copy the file to the backup location
            echo_action "cp \"$FILE\" \"$BACKUP_PATH\""

            # Store the permissions and ownership in a metadata file
            echo_action "echo \"$BACKUP_PATH:$PERMISSIONS:$OWNER\" >> \"$METADATA_FILE\""

            # Log the actions
            log_message "Backed up $FILE to $BACKUP_PATH with permissions $PERMISSIONS and ownership $OWNER"
            print_file_details "$FILE" "$BACKUP_PATH" "$PERMISSIONS" "$OWNER"
        done
    done

    print_success "Backup process completed."
    log_message "Backup process completed."
}

# Replace original jars with the reload4j jar function
replace_with_reload4j() {
    print_info "Starting jar replacement process..."
    log_message "Starting jar replacement process..."

    for JAR in "${JAR_FILES[@]}"; do
        find "$DIR" -type f -name "$JAR" | while read -r FILE; do
            # Skip the specific file you don't want to replace
            if [[ "$FILE" == "/usr/lib/ambari-server/log4j-1.2.17.jar" ]]; then
                print_warning "Skipping replacement of $FILE"
                continue
            fi

            # Determine the directory and the base name of the original JAR file
            DIRNAME=$(dirname "$FILE")
            REPLACEMENT_PATH="$DIRNAME/reload4j-1.2.19.jar"

            if [ -f "$REPLACEMENT_JAR" ]; then
                # Copy reload4j jar to the directory with a new name
                echo_action "cp \"$REPLACEMENT_JAR\" \"$REPLACEMENT_PATH\""
                log_message "Copied $REPLACEMENT_JAR to $REPLACEMENT_PATH"
                print_info "Copied $REPLACEMENT_JAR to $REPLACEMENT_PATH"
            else
                print_warning "$REPLACEMENT_JAR not found, skipping replacement."
                log_message "$REPLACEMENT_JAR not found, skipping replacement."
            fi
        done
    done

    print_success "Jar replacement process completed."
    log_message "Jar replacement process completed."
}

# Remove original jar files
remove_original_jars() {
    print_info "Starting jar removal process..."
    log_message "Starting jar removal process..."

    for JAR in "${JAR_FILES[@]}"; do
        find "$DIR" -type f -name "$JAR" | while read -r FILE; do
            # Skip the specific file you don't want to remove
            if [[ "$FILE" == "/usr/lib/ambari-server/log4j-1.2.17.jar" ]]; then
                print_warning "Skipping removal of $FILE"
                continue
            fi

            echo_action "rm \"$FILE\""
            log_message "Removed original JAR file $FILE"
            print_info "Removed original JAR file $FILE"
        done
    done

    print_success "Jar removal process completed."
    log_message "Jar removal process completed."
}

# Restore function
restore_jars() {
    print_info "Starting restoration process..."
    log_message "Starting restoration process..."

    # Check if backup directory exists
    if [ ! -d "$BACKUPDIR/usr" ]; then
        print_error "Backup directory $BACKUPDIR/usr does not exist."
        log_message "Backup directory $BACKUPDIR/usr does not exist."
        exit 1
    fi

    # Restore the JAR files from the backup directory
    if [ ! -f "$METADATA_FILE" ]; then
        print_error "Metadata file $METADATA_FILE does not exist."
        log_message "Metadata file $METADATA_FILE does not exist."
        exit 1
    fi

    while IFS=: read -r BACKUP_FILE PERMISSIONS OWNER; do
        if [ -f "$BACKUP_FILE" ]; then
            # Determine the original location
            ORIGINAL_PATH="${BACKUP_FILE#$BACKUPDIR/usr/}"
            ORIGINAL_PATH="/usr/$ORIGINAL_PATH"

            # Create the directory structure if it doesn't exist (only if not dry-run)
            if ! $DRY_RUN; then
                echo_action "mkdir -p \"$(dirname "$ORIGINAL_PATH")\""
            fi

            # Restore the file to the original location
            echo_action "cp \"$BACKUP_FILE\" \"$ORIGINAL_PATH\""

            # Restore permissions and ownership
            echo_action "chmod $PERMISSIONS \"$ORIGINAL_PATH\""
            echo_action "chown $OWNER \"$ORIGINAL_PATH\""

            # Log the actions
            log_message "Restored $BACKUP_FILE to $ORIGINAL_PATH with permissions $PERMISSIONS and ownership $OWNER"
            print_info "Restored $BACKUP_FILE to $ORIGINAL_PATH with permissions $PERMISSIONS and ownership $OWNER"
        fi
    done < "$METADATA_FILE"

    # Remove reload4j JAR files
    print_info "Removing reload4j JAR files..."
    log_message "Removing reload4j JAR files..."

    for JAR in "${JAR_FILES[@]}"; do
        find "$DIR" -type f -name "reload4j-*.jar" | while read -r FILE; do
            echo_action "rm \"$FILE\""
            log_message "Removed reload4j JAR file $FILE"
            print_info "Removed reload4j JAR file $FILE"
        done
    done

    print_success "Restoration process completed."
    log_message "Restoration process completed."
}

# Print summary of actions
print_summary() {
    print_info "Script executed with the following options:"
    print_info "  Backup directory: $BACKUPDIR"
    print_info "  JAR files: ${JAR_FILES[@]}"
    print_info "  Replacement JAR: $REPLACEMENT_JAR"
    print_info "  Dry-run mode: $DRY_RUN"
}

# Main script logic
while getopts ":d" opt; do
    case ${opt} in
        d )
            DRY_RUN=false
            ;;
        \? )
            print_error "Invalid option: -$OPTARG"
            exit 1
            ;;
        : )
            print_error "Invalid option: -$OPTARG requires an argument"
            exit 1
            ;;
    esac
done
shift $((OPTIND -1))


case "$1" in
    backup)
        backup_jars
        ;;
    replace)
        replace_with_reload4j
        remove_original_jars
        ;;
    restore)
        restore_jars
        ;;
    *)
        print_error "Usage: $0 [-d] {backup|replace|restore}"
        echo "  -d: Execute actions (default is dry-run)"
        exit 1
        ;;
esac

# Print summary of actions
print_summary
