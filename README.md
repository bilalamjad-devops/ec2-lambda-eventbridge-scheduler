# Stop Paying for Idle EC2 Instances Using Terraform, EventBridge Scheduler and AWS Lambda

## The Business Problem

Most companies run more than just production servers on AWS. There's almost always a parallel set of EC2 instances for development, testing, and staging — environments that engineers only touch during working hours. The problem is that these instances are usually left running around the clock, even though nobody is using them outside 8 AM–5 PM, Monday to Friday.

That mismatch is pure waste. An instance that's only needed for 9 hours a day is being billed for all 24. Multiply that across a dev team with several non-prod instances, and the unused compute adds up to a real, recurring cost on the AWS bill every single month — for infrastructure nobody was even using.

## Why This Matters

This is one of the most common cost-optimization requests in real DevOps work, and it's also one of the easiest to get wrong manually. Asking engineers to remember to stop instances at the end of the day doesn't scale — people forget, environments multiply, and "I'll stop it later" becomes the default. The fix isn't a reminder, it's automation: a system that starts and stops resources on a schedule without anyone having to think about it.

It's also a great project for showing real AWS and Infrastructure-as-Code skills, because it touches several pieces that show up constantly in production environments: tagging strategy, event-driven architecture, IAM permissions, and serverless compute — all wired together with Terraform instead of manual console clicks.

## What We'll Build in This Lab

By the end of this walkthrough, we'll have:

- A Terraform configuration that provisions two AWS Lambda functions and two Amazon EventBridge schedules
- An EC2 instance tagged so our automation knows it's allowed to manage it
- A start schedule that runs every weekday at 8:00 AM PKT
- A stop schedule that runs every weekday at 5:00 PM PKT
- Verified, working automation — captured below in screenshots of the actual run, including the EC2 instance flipping from stopped to running on schedule

> If you want the full Terraform and Python code with line-by-line explanations, I covered that in detail in [Part 1 of this series](#) — this post focuses on actually deploying it and watching it work end to end.

---

## Step 1: Initialize and Plan the Infrastructure

Before touching anything in the AWS Console, we run the standard Terraform workflow from the project folder. `terraform init` downloads the AWS provider, and `terraform plan` shows exactly what's about to be created — two Lambda functions, two EventBridge rules, the IAM role, and the permissions linking them — without changing anything yet.

<img width="1600" height="900" alt="terraform init and plan output" src="https://github.com/user-attachments/assets/83768fed-4fa5-43ba-b348-651ea1da6d79" />

Reviewing the plan output before applying is good habit to build early — it catches mistakes (wrong region, wrong resource name) before they become real, billed infrastructure.

<img width="1600" height="900" alt="lambda and EventBridge resources in the plan" src="https://github.com/user-attachments/assets/e778594a-e047-46a0-8d1e-27837da151dc" />

<img width="1600" height="900" alt="lambda and EventBridge resources continued" src="https://github.com/user-attachments/assets/555c4f7a-770a-402a-9b9b-cb0a93530277" />

---

## Step 2: Create a Test EC2 Instance and Tag It

Our Lambda functions don't act on every EC2 instance in the account — only on instances explicitly tagged to opt in. That's an important design choice: it means this automation can never accidentally stop a production server that wasn't meant to be touched.

To test it, we launch a fresh EC2 instance from the console:

<img width="1600" height="900" alt="EC2 launch instance screen" src="https://github.com/user-attachments/assets/ed8123b5-6e68-4040-a804-1165d7fc6822" />

During launch, under "Add additional tags," we add the tag our Lambda functions are configured to look for:

```
Key:   AutoSchedule
Value: True
```

<img width="1600" height="900" alt="adding additional tags during EC2 launch" src="https://github.com/user-attachments/assets/b3b269eb-9f16-4ed7-a6f0-d0bac4ee1e3b" />

<img width="1600" height="900" alt="adding the AutoSchedule tag" src="https://github.com/user-attachments/assets/44092bb4-70fe-4cc4-b10d-bed32eae5d42" />

<img width="1600" height="900" alt="AutoSchedule key and value set to True" src="https://github.com/user-attachments/assets/94c31fbf-df2a-4bf9-abe8-55c59a1e6b1e" />

For this lab, the instance was launched without a key pair and with a fresh security group, since we only need to observe its running/stopped state — not SSH into it. (For anything beyond a quick test, attach a key pair as normal.)

<img width="1600" height="900" alt="EC2 instance launching" src="https://github.com/user-attachments/assets/b503a9bc-68fe-4064-8b54-4437ac8d4bab" />

<img width="1600" height="900" alt="EC2 instance running after launch" src="https://github.com/user-attachments/assets/ddcf38a8-6db0-437d-b004-2923a3f476ec" />

Without this tag, the instance is invisible to our scheduler entirely — it would just sit there, untouched, regardless of what time it is.

---

## Step 3: Set the Instance State to Match the Schedule

This is the part that makes the demo actually interesting to watch. Our EventBridge rules are configured as:

```
description         = "Start EC2 instances daily at 8:00 AM PKT"
schedule_expression = "cron(0 3 ? * MON-FRI *)"
```

```
description         = "Stop EC2 instances daily at 5:00 PM PKT"
schedule_expression = "cron(0 12 ? * MON-FRI *)"
```

At the time of this test, it's **7:50 AM** — ten minutes before the start rule is due to fire. To actually see the automation do something, we need the instance in a state where the next scheduled action will change it. So we intentionally stop the instance now:

<img width="1600" height="900" alt="EC2 instance time showing 7:50 AM before the scheduled start" src="https://github.com/user-attachments/assets/33c78aad-de07-44f4-a9ee-f04effb2dc76" />

<img width="1600" height="900" alt="manually stopping the EC2 instance to set up the test" src="https://github.com/user-attachments/assets/73df6164-3708-43a3-9a4b-79346df542cc" />

The logic here: once it's 8:00 AM, EventBridge will trigger the `StartEC2Daily` Lambda, which will find this stopped, tagged instance and start it — with no manual intervention.

---

## Step 4: Deploy with Terraform Apply

Now, at **8:11 AM**, we run the real deployment:

```bash
terraform apply
```

Typing `yes` at the confirmation prompt creates everything in one pass:

- **2 EventBridge schedules** — one cron rule for 8 AM Mon–Fri (start), one for 5 PM Mon–Fri (stop)
- **2 Lambda functions** — one triggered by the start rule, one triggered by the stop rule

<img width="1600" height="900" alt="CloudWatch confirming resources created after terraform apply" src="https://github.com/user-attachments/assets/096f2f0c-29de-4063-a2de-30ffb6d0ea4d" />

<img width="1600" height="900" alt="EventBridge rule showing the scheduled trigger time" src="https://github.com/user-attachments/assets/2eb45233-a09d-4bba-baa6-a2fbea128ff5" />

Because we applied this at 8:11 AM — just after the 8:00 AM trigger point — the next thing to check is whether the rule already fired, or whether it's about to.

---

### Verifying the EventBridge Schedules

Before trusting any automation, it's worth confirming in the console that what Terraform deployed actually matches what we intended. Under **EventBridge → Rules → Scheduled rules**, we can inspect both rules directly:

<img width="1600" height="900" alt="EventBridge schedule rule details" src="https://github.com/user-attachments/assets/dc794fa0-a11b-4acb-aa51-bd12572a03e7" />

<img width="1600" height="900" alt="EventBridge rule cron expression" src="https://github.com/user-attachments/assets/43021e9c-5953-4012-a754-d417fb1de28f" />

<img width="1600" height="900" alt="EventBridge rule target configuration" src="https://github.com/user-attachments/assets/17db874c-64dc-4b95-9e6e-1f25ba85abce" />

<img width="1600" height="900" alt="EventBridge second rule details" src="https://github.com/user-attachments/assets/679aefd7-cf61-4dbf-a8ee-d5c9eaca62e3" />

<img width="1600" height="900" alt="EventBridge second rule cron expression" src="https://github.com/user-attachments/assets/0daf3657-87e4-4d96-85fd-2c4118a0026f" />

<img width="1600" height="900" alt="EventBridge second rule target configuration" src="https://github.com/user-attachments/assets/dc598b43-1c26-4d11-9165-630d2fb2e4d5" />

<img width="1600" height="900" alt="EventBridge rules list overview" src="https://github.com/user-attachments/assets/0ea2384a-1f3d-46eb-b9ad-8560d8c1b6a7" />

<img width="1600" height="900" alt="EventBridge rule enabled status" src="https://github.com/user-attachments/assets/d31f4643-daaa-48e8-99e9-bce07f16c182" />

<img width="1600" height="900" alt="EventBridge rule final check" src="https://github.com/user-attachments/assets/e39b76fd-aafc-42ff-aed7-c33b0da93c0e" />

Remember that EventBridge cron expressions are always in UTC. `cron(0 3 ? * MON-FRI *)` means 3:00 AM UTC, which is 8:00 AM PKT (UTC+5) — exactly the start of the workday we're targeting.

---

### Verifying the Lambda Functions

Next, under **Lambda → Functions**, we confirm both functions deployed correctly with the right runtime, handler, memory, and IAM role attached:

<img width="1600" height="900" alt="Lambda functions list showing StartEC2Daily and StopEC2Daily" src="https://github.com/user-attachments/assets/21114dac-a42e-49d1-a4fa-d4a2fd168b1d" />

<img width="1600" height="900" alt="Lambda function configuration overview" src="https://github.com/user-attachments/assets/6c57583c-06b5-4dbf-97f0-e27024d0f4c3" />

<img width="1600" height="900" alt="Lambda function runtime and handler settings" src="https://github.com/user-attachments/assets/e1157253-e792-463e-b097-43105e792484" />

<img width="1600" height="900" alt="Lambda function permissions tab showing attached IAM role" src="https://github.com/user-attachments/assets/20f66b81-4738-4164-a1e5-07fefe2b8552" />

<img width="1600" height="900" alt="Lambda function general configuration" src="https://github.com/user-attachments/assets/8d051c6a-0e21-4e99-93ee-7b295d010e29" />

Checking the **Permissions** tab matters here — it's how we confirm the `EC2SchedulerLambdaRole` is actually attached, which is what gives the function the rights to call `DescribeInstances` and `StartInstances`/`StopInstances`.

---

### Verifying Execution in CloudWatch

The EC2 console tells you *that* something changed, but CloudWatch Logs tell you *why* — which instances the Lambda found, and whether it ran successfully.

<img width="1600" height="900" alt="CloudWatch log group for Lambda function" src="https://github.com/user-attachments/assets/a9ab96b1-63d4-4e99-81b9-8e31d44e8bcc" />

<img width="1600" height="900" alt="CloudWatch log stream entries" src="https://github.com/user-attachments/assets/e320abaa-53e3-418c-8b0a-173b6aa70cd6" />

<img width="1600" height="900" alt="CloudWatch log details showing instance IDs found" src="https://github.com/user-attachments/assets/cb2a319b-4a9c-4a6e-a583-aaf687f66118" />

This is the layer that makes the automation auditable — if something doesn't start or stop as expected, this is the first place to look.

---

## Step 5: Result: EC2 Instance Started Automatically

This is the actual proof that the system works end to end. The instance we manually stopped at 7:50 AM has, by the scheduled trigger time, transitioned from `stopped` to `running` — with no one touching the console:

<img width="1600" height="900" alt="EC2 instance state changed to running automatically" src="https://github.com/user-attachments/assets/77fc0e19-3ed6-4a92-998f-33121b1ae5e7" />

EventBridge fired on schedule, invoked the `StartEC2Daily` Lambda, the Lambda found our tagged, stopped instance, and called `start_instances` on it. The same chain runs in reverse at 5:00 PM to stop it again — fully automated, fully tag-scoped, and costing fractions of a cent in Lambda execution time to run.

---

## Step 6: Clean Up — Terraform Destroy

Once the lab is verified, the schedulers, Lambda functions, and IAM role aren't needed anymore unless you intend to keep using this in a real environment. To avoid leaving anything billable running:

```bash
terraform destroy
```

<img width="1600" height="900" alt="terraform destroy command output" src="https://github.com/user-attachments/assets/4665c3b3-fb24-479b-ac92-0785710092b5" />

<img width="1600" height="900" alt="terraform destroy completion confirmation" src="https://github.com/user-attachments/assets/7065b1a9-bad8-4493-b7bc-02d3634b3922" />

Type `yes` to confirm. Terraform only manages what it created — the manually launched test EC2 instance still needs to be terminated separately from the EC2 console.

---

## Conclusion

This walkthrough proves out something simple but valuable: a tag-based, serverless EC2 scheduler that starts and stops non-production instances automatically, on a clean Terraform-managed schedule, with zero manual intervention once deployed.

The pattern here generalizes well beyond EC2 — the same tag-and-trigger approach works for RDS instances, Auto Scaling Groups, or any AWS resource with a start/stop API. For a team running multiple non-prod environments, this is a low-effort way to cut a real, recurring cost every month.

---

*Code and full Terraform/Python source for this project are available on [GitHub](#) — link your repo here.*
