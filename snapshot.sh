#!/usr/bin/env bash
#
# This script will snapshot all the containers.

set -e
set -o pipefail
set -x

# Services whose containers will be `docker commit`ed
IMAGE_SERVICES=(
    "chrome"
    "credentials"
    "devpi"
    "discovery"
    "ecommerce"
    "edx_notes_api"
    "firefox"
    "forum"
    "lms"
)

# Services whose volumes will be snapshotted
VOLUME_SERVICES=(
    "credentials"
    "devpi"
    "discovery"
    "ecommerce"
    "elasticsearch"
    "gradebook"
    "lms"
    "mongo"
    "mysql"
    "studio"
)

# Volumes will only be snapshotted if they match the following jq patterns
JQ_VOLUME_MATCHES=(
    "_assets$"
    "_data$"
    "_node_modules$"
)

# Convert array to a '|' separated string
IFS=\| eval 'JQ_VOLUME_MATCHES="${JQ_VOLUME_MATCHES[*]}"'

# Since they'll be used more than once below, declare the jq queries up front.
JQ_IMAGE_QUERY=".[].Config.Image"
JQ_VOLUME_QUERY=".[].Mounts[] | select(has(\"Name\")) | select(.Name | test(\"${JQ_VOLUME_MATCHES}\")) | .Source"

snapshot_containers () {
    for service in ${IMAGE_SERVICES[*]}; do
        container_id=$(docker-compose $DOCKER_COMPOSE_FILES ps -q $service)
        if [ -n "$container_id" ]; then
            container_image=$(docker inspect $container_id | jq -r "$JQ_IMAGE_QUERY")
            container_image_base=${container_image%:*}
            container_image_snapshot=${container_image_base}:${SNAPSHOT_NAME}
            docker commit $container_id $container_image_snapshot
        fi
    done
}

snapshot_volumes () {
    for service in ${VOLUME_SERVICES[*]}; do
        container_id=$(docker-compose $DOCKER_COMPOSE_FILES ps -q $service)
        if [ -n "$container_id" ]; then
            volume_dirs=$(docker inspect $container_id | jq -r "$JQ_VOLUME_QUERY" | uniq)
            for volume_dir in $volume_dirs; do
                if [ -n "$volume_dir" ]; then
                    if ! sudo btrfs subvolume show $volume_dir; then
                        # Convert directory to a subvolume
                        sudo mv $volume_dir ${volume_dir}-org
                        sudo btrfs subvolume create $volume_dir
                        sudo rsync -a ${volume_dir}-org/ ${volume_dir}/
                        sudo rm -fr ${volume_dir}-org
                    fi
                    snapshot_dir=${volume_dir}-${SNAPSHOT_NAME}
                    if sudo btrfs subvolume show $snapshot_dir; then
                        # Snapshot exists.  Remove it.
                        sudo btrfs subvolume delete $snapshot_dir
                    fi
                    sudo btrfs subvolume snapshot $volume_dir $snapshot_dir
                fi
            done
        fi
    done
}

restore_volumes () {
    for service in ${VOLUME_SERVICES[*]}; do
        container_id=$(docker-compose $DOCKER_COMPOSE_FILES ps -q $service)
        if [ -n "$container_id" ]; then
            volume_dirs=$(docker inspect $container_id | jq -r "$JQ_VOLUME_QUERY" | uniq)
            for volume_dir in $volume_dirs; do
                snapshot_dir=${volume_dir}-${SNAPSHOT_NAME}
                if [ -n "$volume_dir" -a -e "$snapshot_dir" ]; then
                    if sudo btrfs subvolume show $snapshot_dir; then
                        # Snapshot exists and is a btrfs subvolume.  Remove
                        # original directory and replace it with the snapshot.
                        if sudo btrfs subvolume show $volume_dir; then
                            sudo btrfs subvolume delete $volume_dir
                        else
                            sudo rm -fr $volume_dir
                        fi
                        sudo mv $snapshot_dir $volume_dir
                        sudo btrfs subvolume snapshot $volume_dir $snapshot_dir
                    fi
                fi
            done
        fi
    done
}

ACTION=${1:-snapshot}
SNAPSHOT_NAME=${2:-snapshot}

if [ "$ACTION" == "snapshot" ]; then
    snapshot_containers
    snapshot_volumes
elif [ "$ACTION" == "restore" ]; then
    restore_volumes
fi
