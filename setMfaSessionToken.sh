#!/bin/bash
which aws &> /dev/null
if [ $? -ne 0 ]; then
  echo "ERROR - AWS CLI is not installed"
  exit 1
fi

usage="$(basename "$0") -p profile_name [-h|help] [-d n] [-o] [-r] -- Generates the temporary session token for the AWS profile,
prompts for the MFA token. If the credentials are still valid (not expired) then the script will not regenerate them. This
behavior can be overridden by using the '-o' option

where:
    -h|help show this help text
    -p      required profile name for the spoke AWS account
    -d      set the session duration in seconds [15 minutes to 12 hrs] (default: 43200 - i.e., 12hrs)
    -o      override the session expiration and regenerate the credentials
    -r      mfa cli profile"


# Set default duration in seconds 43200 == 12hrs
DURATION_SECONDS=43200

# Set default region
DEFAULT_REGION="us-east-1"

# Set default output
DEFAULT_OUTPUT="json"


while getopts ":p:hhelpod:p:r:" ARGS;
do
    case $ARGS in
        h )
            echo "$usage"
            exit 1
            ;;
        p)
            AWS_PROFILE=${OPTARG};;
        d)
            DURATION_SECONDS=${OPTARG};;
        o)
            OVERRIDE="true";;
        r)
            MFA_PROFILE_NAME=${OPTARG};;
        \? )
            echo ""
            echo "Unimplemented option: -$OPTARG" >&2
            echo ""
            exit 1
            ;;
        : )
            echo ""
            echo "Option -$OPTARG needs an argument." >&2
            echo ""
            exit 1
            ;;
        * )
            echo "$usage"
            exit 1
            ;;
    esac
done

if [ -z $AWS_PROFILE ]; then
    echo "AWS Profile is required"
    exit 1
fi

if [ -z $MFA_PROFILE_NAME ]; then
    # Set the "temp" cli profile name
    MFA_PROFILE_NAME=$AWS_PROFILE'-cli'
fi

CIA_ACCOUNT=$(aws configure get source_profile --profile $AWS_PROFILE)
if [ -z $CIA_ACCOUNT ]; then
    echo "Error - source_profile not found in: $AWS_PROFILE profile"
    exit 1
fi

MFA_SERIAL=$(aws configure get mfa_serial --profile $AWS_PROFILE)
if [ -z $MFA_SERIAL ]; then
    echo "Error - mfa_serial not found in: $AWS_PROFILE profile"
    exit 1
fi

ROLE_ARN=$(aws configure get role_arn --profile $AWS_PROFILE)
if [ -z $ROLE_ARN ]; then
    echo "Error - role_arn not found in: $AWS_PROFILE profile"
    exit 1
fi


# Generate Security Token Flag
GENERATE_ST="true"

if [ -z $OVERRIDE ]; then
    # Expiration Time: Each SessionToken will have an expiration time which by default is 12 hours and
    # can range between 15 minutes and 12 hours
    MFA_PROFILE_NAME_EXISTS=$(grep -c $MFA_PROFILE_NAME ~/.aws/credentials)
    if [ $MFA_PROFILE_NAME_EXISTS -eq 1 ]; then
        EXPIRATION_TIME=$(aws configure get expiration --profile $MFA_PROFILE_NAME)
        NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        if [[ "$EXPIRATION_TIME" > "$NOW" ]]; then
            echo "The Session Token is still valid. New Security Token not required."
            GENERATE_ST="false"
        fi
    fi
fi

# see: https://gist.github.com/cjus/1047794
function jsonValue {
    sed 's/\\\\\//\//g' | sed 's/[{}]//g' | awk -v k="text" '{n=split($0,a,","); for (i=1; i<=n; i++) print a[i]}' | sed 's/\"\:\"/\|/g' | sed 's/[\,]/ /g' | sed 's/\"//g' | grep -w $1 | cut -d":" -f2- | sed -e 's/^ *//g' -e 's/ *$//g'
}

if [ "$GENERATE_ST" = "true" ];then
    read -p "Token code for MFA Device ($MFA_SERIAL): " TOKEN_CODE
    # Do the assume-role call
    echo "Generating new Assume Role STS Token ..."
    TEMP_CREDS=$(aws sts assume-role --profile $CIA_ACCOUNT --output json --query 'Credentials' --role-arn $ROLE_ARN --role-session-name $(whoami) --duration-seconds $DURATION_SECONDS --serial-number $MFA_SERIAL --token-code $TOKEN_CODE)
    if [ $? -ne 0 ];then
        echo "An error occurred assuming the role. AWS credentials file not updated"
    else
        AR_AWS_SECRET_ACCESS_KEY=$(echo $TEMP_CREDS | jsonValue SecretAccessKey)
        AR_AWS_SESSION_TOKEN=$(echo $TEMP_CREDS | jsonValue SessionToken)
        AR_AWS_ACCESS_KEY_ID=$(echo $TEMP_CREDS | jsonValue AccessKeyId)
        AR_EXPIRATION=$(echo $TEMP_CREDS | jsonValue Expiration)

        aws configure set aws_secret_access_key "$AR_AWS_SECRET_ACCESS_KEY" --profile $MFA_PROFILE_NAME
        aws configure set aws_session_token "$AR_AWS_SESSION_TOKEN" --profile $MFA_PROFILE_NAME
        aws configure set aws_access_key_id "$AR_AWS_ACCESS_KEY_ID" --profile $MFA_PROFILE_NAME
        aws configure set expiration "$AR_EXPIRATION" --profile $MFA_PROFILE_NAME
        aws configure set region "$DEFAULT_REGION" --profile $MFA_PROFILE_NAME
        aws configure set output "$DEFAULT_OUTPUT" --profile $MFA_PROFILE_NAME
        echo "Assume Role Session Token (valid until $AR_EXPIRATION) added to your AWS credentials. Use \"--profile $MFA_PROFILE_NAME\" for the next AWS CLI command."
    fi
fi
