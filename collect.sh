print_env_vars() {
	for var in "$@"; do
		echo "$var=${!var}"
	done
}

main() {
    local PROJECT=$1
	local BUILD_STAMP METAPKG MASCOT CODENAME JIRA_OBJECTIVE
	local BUILD_NUMBER PLATFORM_CODENAME PRODUCT_FAMILY BIOS_VERSION SUDO_NOPASSWD

	BUILD_STAMP=$(grep -e "^[^#]" /var/lib/ubuntu_dist_channel)
	# Build number is the last part of the build stamp ("-" separated)
	BUILD_NUMBER=${BUILD_STAMP##*-}
	if [ -z "$BUILD_NUMBER" ]; then
		>&2 echo "Failed to get build number or platform code name"
		exit 1
	fi

	# Get the code name of the distribution: fossa, jellyfish, etc.
	. /etc/os-release
	MASCOT=$(echo "$VERSION" | grep -oE "[[:alpha:]]+" | tail -n1)
	# Get the Platform code name
	METAPKG=$(dpkg -l | grep -oE "oem-$PROJECT-\w+-meta" | grep -v "factory")
	CODENAME=$(echo "$METAPKG" | cut -d- -f3)
	if [ -z "$CODENAME" ]; then
		>&2 echo "Failed to get platform code name"
	else
		# shellcheck disable=SC2034
		PLATFORM_CODENAME="${MASCOT,,}-$CODENAME"
		local CHANGELOG_FILE="/usr/share/doc/oem-$PROJECT-$CODENAME-meta/changelog.gz"
		if [ ! -f "$CHANGELOG_FILE" ]; then
			>&2 echo "Failed to get changelog"
		else
			JIRA_OBJECTIVE=$(zcat "$CHANGELOG_FILE" | grep -oP "JIRA: \K(${PROJECT^^}-\d+)")
			if [ -z "$JIRA_OBJECTIVE" ]; then
				>&2 echo "Failed to get JIRA objective"
			fi
		fi
	fi

	PRODUCT_FAMILY=$(cat /sys/class/dmi/id/product_family)
	if [ -z "$PRODUCT_FAMILY" ]; then
		PRODUCT_FAMILY="Unknown"
	fi

	BIOS_VERSION=$(cat /sys/class/dmi/id/bios_version)
	if [ -z "$BIOS_VERSION" ]; then
		BIOS_VERSION="Unknown"
	fi

    # Check if the user is allowed to run sudo without password
    if sudo -n true &> /dev/null; then
        SUDO_NOPASSWD="true"
    else
        # shellcheck disable=SC2034
        SUDO_NOPASSWD="false"
    fi

	print_env_vars BUILD_NUMBER PLATFORM_CODENAME PRODUCT_FAMILY BIOS_VERSION JIRA_OBJECTIVE SUDO_NOPASSWD
}

main "sutton"
