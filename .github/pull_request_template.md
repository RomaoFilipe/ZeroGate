## Description

<!-- What does this PR change and why? -->

## Type of change

- [ ] Infrastructure (Terraform)
- [ ] Docker / service configuration
- [ ] Operational script
- [ ] Documentation
- [ ] Security policy
- [ ] Bug fix
- [ ] Dependency version update

## Security checklist

- [ ] No secrets, tokens, or passwords added to any tracked file
- [ ] `terraform plan` reviewed — zero inbound rules on security group preserved
- [ ] No ports published to `0.0.0.0` in `docker-compose.yml`
- [ ] New services added to `zerogate-internal` network only
- [ ] Image versions pinned to exact tag (no `latest`)
- [ ] `make audit` passes on the target environment

## Testing done

- [ ] `make health` passes
- [ ] `make audit` passes
- [ ] Manually tested on dev/staging instance
- [ ] Auth flow tested end-to-end (login → MFA → resource access)

## For auth / access policy changes

- [ ] Reviewed by a second person
- [ ] Tested that MFA is still enforced after the change
- [ ] Tested that revoked users cannot access resources

## Notes

<!-- Anything reviewers should know, gotchas, follow-ups -->
