import boto3
import os
 
ec2 = boto3.client('ec2')
 
TAG_KEY = os.environ.get('TAG_KEY', 'AutoSchedule')
TAG_VALUE = os.environ.get('TAG_VALUE', 'True')
 
def lambda_handler(event, context):
    print("--- Starting EC2 instances process initiated ---")
    print(f"Looking for instances with tag '{TAG_KEY}':'{TAG_VALUE}'")
 
    filters = [
        {'Name': 'instance-state-name', 'Values': ['stopped']},
        {'Name': f'tag:{TAG_KEY}', 'Values': [TAG_VALUE]}
    ]
 
    instances_to_start = []
    try:
        response = ec2.describe_instances(Filters=filters)
        for reservation in response['Reservations']:
            for instance in reservation['Instances']:
                instances_to_start.append(instance['InstanceId'])
 
        if instances_to_start:
            print(f"Found {len(instances_to_start)} instances to start: {instances_to_start}")
            ec2.start_instances(InstanceIds=instances_to_start)
            print("Successfully sent start command to EC2 instances.")
        else:
            print("No stopped instances found with the specified tag.")
 
    except Exception as e:
        print(f"Error starting EC2 instances: {e}")
        return {'statusCode': 500, 'body': f"Error starting EC2 instances: {str(e)}"}
 
    print("--- EC2 instances start process completed ---")
    return {'statusCode': 200, 'body': 'EC2 instance start process completed.'}
