#!/usr/bin/env bash

# Script intended for running Deckhand integration tests, where integration
# is defined as the interaction between Deckhand and Keystone and Barbican.
# Installation dependency is openstack-helm-infra.
#
# USAGE: ./tools/integration-tests.sh <test-regex>

# TODO(fmontei): Use Ansible for all this.
# NOTE(fmontei): May have to automate the following installation guide for CI:
# https://docs.openstack.org/openstack-helm/latest/install/developer/requirements-and-host-config.html#host-configuration

set -xe

CURRENT_DIR="$(pwd)"
: ${OSH_INFRA_PATH:="../openstack-helm-infra"}
: ${OSH_PATH:="../openstack-helm"}


function deploy_barbican {
    set -xe

    # Pull images and lint chart
    make pull-images barbican

    # Deploy command
    helm upgrade --install barbican ./barbican \
        --namespace=openstack

    # Wait for deploy
    ./tools/deployment/common/wait-for-pods.sh openstack

    # Validate deployment info
    helm status barbican
}


function deploy_osh_keystone_barbican {
    set -xe

    if [ ! -d "$OSH_INFRA_PATH" ]; then
        git clone https://git.openstack.org/openstack/openstack-helm-infra.git ../openstack-helm-infra
    fi

    if [ ! -d "$OSH_PATH" ]; then
        git clone https://git.openstack.org/openstack/openstack-helm.git ../openstack-helm
    fi

    cd ${OSH_INFRA_PATH}
    # NOTE(fmontei): setup-host already sets up required host dependencies.
    make dev-deploy setup-host
    make dev-deploy k8s

    cd ${CURRENT_DIR}
    sudo -H -E pip install -r test-requirements.txt

    cd ${OSH_PATH}
    # Setup clients on the host and assemble the charts¶
    ./tools/deployment/developer/common/020-setup-client.sh
    # Deploy the ingress controller
    ./tools/deployment/developer/common/030-ingress.sh
    # Deploy NFS Provisioner
    ./tools/deployment/developer/nfs/040-nfs-provisioner.sh
    # Deploy MariaDB
    ./tools/deployment/developer/nfs/050-mariadb.sh
    # Deploy RabbitMQ
    ./tools/deployment/developer/nfs/060-rabbitmq.sh
    # Deploy Memcached
    ./tools/deployment/developer/nfs/070-memcached.sh
    # Deploy Keystone
    ./tools/deployment/developer/nfs/080-keystone.sh

    deploy_barbican
}


function deploy_deckhand {
    set -xe

    export OS_CLOUD=openstack_helm

    cd ${CURRENT_DIR}

    # TODO(fmontei): Use Keystone bootstrap override instead.
    interfaces=("admin" "public" "internal")
    deckhand_endpoint="http://127.0.0.1:9000"

    if [ -z "$( openstack service list --format value | grep deckhand )" ]; then
        openstack service create --enable --name deckhand deckhand
    fi

    for iface in ${interfaces[@]}; do
        if [ -z "$( openstack endpoint list --format value | grep deckhand | grep $iface )" ]; then
            openstack endpoint create --enable \
                --region RegionOne \
                deckhand $iface $deckhand_endpoint/api/v1.0
        fi
    done

    openstack service list | grep deckhand
    openstack endpoint list | grep deckhand

    gen_config false $deckhand_endpoint
    gen_paste false

    log_section "Running Deckhand via uwsgi."

    source ${CURRENT_DIR}/entrypoint.sh alembic upgrade head &
    # Give time for migrations to complete.
    sleep 10

    source ${CURRENT_DIR}/entrypoint.sh server &
    # Give the server a chance to come up. Better to poll a health check.
    sleep 10

    # NOTE(fmontei): Generate an admin token instead of hacking a policy
    # file with no permissions to test authN as well as authZ.
    export TEST_AUTH_TOKEN=$( openstack token issue --format value -c id )
    local test_barbican_url=$( openstack endpoint list --format value | grep barbican | grep public | awk '{print $7}' )

    if [[ $test_barbican_url == */ ]]; then
        test_barbican_url=$( echo $test_barbican_url | sed 's/.$//' )
    fi

    export TEST_BARBICAN_URL=$test_barbican_url
}


function run_tests {
    set +e

    export DECKHAND_TEST_DIR=${CURRENT_DIR}/deckhand/tests/integration/gabbits

    posargs=$@
    if [ ${#posargs} -ge 1 ]; then
        stestr --test-path deckhand/tests/common/ run --serial --slowest --force-subunit-trace --color $1
    else
        stestr --test-path deckhand/tests/common/ run --serial --slowest --force-subunit-trace --color
    fi
    TEST_STATUS=$?

    set -e

    if [ "x$TEST_STATUS" = "x0" ]; then
        log_section Done SUCCESS
    else
        log_section Done FAILURE
        exit $TEST_STATUS
    fi
}


source ${CURRENT_DIR}/tools/common-tests.sh

export AIRSHIP_DECKHAND_DATABASE_URL=${PIFPAF_POSTGRESQL_URL}

# Clone openstack-helm-infra and setup host and k8s.
deploy_osh_keystone_barbican

# Deploy Deckhand.
deploy_deckhand

run_tests "$@"
