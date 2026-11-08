# Phase 2 — Network (VPC, Subnets, Routing, Security Groups)

## What was built (`infra/`, state key `infra/terraform.tfstate`)

```
VPC 10.20.0.0/16  (DNS support + hostnames on)
├── public-a   10.20.1.0/24   ap-southeast-2a ─┐
├── public-b   10.20.2.0/24   ap-southeast-2b ─┴─ public-rt : 10.20.0.0/16 → local, 0.0.0.0/0 → IGW
├── private-a  10.20.11.0/24  ap-southeast-2a ─┐
└── private-b  10.20.12.0/24  ap-southeast-2b ─┴─ private-rt: 10.20.0.0/16 → local   (no internet)

web SG : in 80, 443 from 0.0.0.0/0 · out 80/443 to internet · out 3306 → db SG
db SG  : in 3306 from web SG only    · no egress
default SG : taken over with zero rules (locked)
```
22 resources, all free (VPC, subnets, route tables, IGW and security groups cost nothing).

## Terraform techniques used
| Technique | Where | Why |
|---|---|---|
| `data "aws_availability_zones"` + `slice()` | `locals.tf` | No hard-coded AZ names; `az_count` decides how many. |
| `for` expression building a **map** | `local.public_subnets`, `local.private_subnets` | Feeds `for_each` with stable keys (`public-a`). |
| `cidrsubnet(vpc_cidr, 8, n)` | subnet CIDRs | /16 + 8 bits = /24; `n` picks the 3rd octet. Change the VPC CIDR and every subnet follows. |
| `merge()` | `local.subnets` | One `aws_subnet` resource for both tiers. |
| list(object) → map | `local.web_ingress_rules` | `for_each` needs a map/set; key = `"port-cidr"`. |
| `validation` blocks | `variables.tf` | Fail at plan time with a clear message instead of an AWS API error. |
| Separate SG rule resources | `security_groups.tf` | `aws_vpc_security_group_ingress_rule` is the current recommended style: one resource per rule, clean diffs, no inline/standalone conflicts. |
| `name_prefix` + `create_before_destroy` | SGs | A replaced SG can coexist with the old one while instances are moved over. |
| `aws_default_security_group` | `network.tf` | Adopts the VPC's default SG and strips all rules (CIS AWS 5.4). |

### Why `for_each` with a map and not `count`?
```hcl
# count: resources are addressed by index
aws_subnet.this[0]  # public-a
aws_subnet.this[1]  # public-b
# remove the first item from the list -> [1] becomes [0] -> Terraform destroys/recreates subnets that didn't change

# for_each: addressed by key
aws_subnet.this["public-a"]
aws_subnet.this["public-b"]  # unaffected when public-a is removed
```

## Design decisions
- **No NAT Gateway** (~$0.059/h + data ≈ $45+/month). Private subnets only host RDS, which needs no outbound internet.
  Alternatives when private workloads need egress: NAT Gateway (managed, HA per AZ), NAT instance (cheap, you
  maintain it), or **VPC endpoints** (Gateway endpoints for S3/DynamoDB are free; Interface endpoints ≈ $7/month each).
- **No public IP auto-assign** (`map_public_ip_on_launch = false`): every public IPv4 is billed (~$3.6/month);
  the web instance will get one explicit Elastic IP in Phase 4.
- **No port 22**: shell access will be via **SSM Session Manager** — no SSH keys, no open port, every session audited.
- **SG references instead of CIDRs for DB access**: rule says "members of web SG", so it keeps working when the
  instance is replaced, its IP changes, or we scale to an Auto Scaling Group.
- **Two AZs**: an RDS DB subnet group requires subnets in at least two AZs, even for single-AZ instances.

## Verification commands
```powershell
terraform output
terraform state list
terraform plan -detailed-exitcode    # 0 = no drift, 2 = changes, 1 = error
aws ec2 describe-route-tables --filters Name=vpc-id,Values=<vpc-id> --output table
aws ec2 describe-security-group-rules --filters Name=group-id,Values=<sg-id> --output table
```
Note: the route table list shows a third, unnamed table — that is the VPC's **main route table**, created
automatically with every VPC. Subnets without an explicit association use it. All our subnets are explicitly
associated, so it is unused (it could be adopted with `aws_default_route_table`, like the default SG).

## Concepts
- **Public vs private subnet** is not a checkbox: a subnet is "public" only because its route table has
  `0.0.0.0/0 → Internet Gateway`. Instances additionally need a public IP/EIP to be reachable.
- **Security Group vs NACL**: SGs are stateful, attached to ENIs, allow-only. NACLs are stateless, attached to subnets,
  have allow + deny and rule numbers (return traffic on ephemeral ports 1024-65535 must be allowed explicitly).
- **Reserved IPs**: AWS reserves 5 addresses in each subnet (network, VPC router, DNS, future use, broadcast) →
  a /24 has 251 usable addresses.
- **Regional vs zonal**: VPC, route tables, SGs are regional; subnets are zonal (one AZ each).

## Interview Q&A
- **Q: Your EC2 in a "public" subnet can't reach the internet. What do you check?**
  A: Route table has `0.0.0.0/0 → igw-*` and is associated with that subnet; instance has a public IP or EIP;
  SG egress allows the traffic; NACL allows outbound and inbound ephemeral ports; OS firewall; DNS resolution enabled.
- **Q: How do private instances download updates without a public IP?**
  A: NAT Gateway in a public subnet (route `0.0.0.0/0 → nat-*` in the private RT), or VPC endpoints for AWS
  services (S3 gateway endpoint for yum/dnf mirrors on Amazon Linux, interface endpoints for ECR/SSM).
- **Q: Why reference a security group instead of an IP range for DB access?**
  A: Identity-based: works with changing IPs and auto scaling, documents intent, and is tighter than a subnet CIDR.
- **Q: `count` vs `for_each`?**
  A: `count` for N identical copies or on/off toggles (`count = var.enabled ? 1 : 0`); `for_each` for distinct
  items with stable identity. Removing an item from a `count` list shifts indexes and causes destroy/recreate.
- **Q: How would you plan CIDRs for multiple environments / VPC peering?**
  A: Non-overlapping ranges per env/account (e.g. dev 10.20/16, staging 10.30/16, prod 10.40/16), documented in
  an IPAM plan (or AWS VPC IPAM), leaving room to grow; overlapping CIDRs cannot be peered or routed via TGW.

## Teardown
Network resources are free, so they can stay. `terraform destroy` in `infra/` removes them if needed.
