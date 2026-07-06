# Contributing to OpenPhone

Thanks for helping with OpenPhone. This repository is source-available, not open
source. Contributions are accepted only under the contributor terms below.

If you do not agree to these terms, do not submit a pull request, patch, issue
comment with code, design asset, documentation change, or other contribution.

## Ownership And License

OpenPhone is proprietary software and project material owned by Dafdef, inc.
The repository is licensed under the non-commercial source-available license in
[LICENSE](../LICENSE), unless a file-specific or third-party notice says
otherwise.

You may use repository access to review the code, run the project locally for
development and evaluation, and propose contributions. You may not use the code
commercially, redistribute it, run a competing product with it, or publish it
outside this repository without written permission from Dafdef, inc.

## Contributor Agreement

By submitting a pull request, patch, commit, issue comment containing code or
creative material, documentation, design asset, test, configuration, schema,
script, workflow, or any other contribution to this repository, you agree to
the following terms.

### Assignment

To the fullest extent permitted by law, you hereby assign and agree to assign to
Dafdef, inc. all right, title, and interest in and to your contributions,
including all copyrights and other intellectual property rights.

If an assignment is not permitted by law, is ineffective, or does not apply to
any portion of your contribution, you instead grant Dafdef, inc. an irrevocable,
perpetual, worldwide, exclusive, transferable,
sublicensable, royalty-free, fully paid-up license to use, reproduce, modify,
prepare derivative works of, publish, perform, display, distribute, host,
commercialize, sell, license, sublicense, relicense, import, export, and
otherwise exploit your contribution in any way and under any license or business
model, including proprietary and closed-source products, without compensation or
further approval.

### Patent License

To the extent you have or later obtain patent rights that would be infringed by
your contribution alone or by combination of your contribution with this project,
you grant Dafdef, inc. an irrevocable, perpetual, worldwide, transferable,
sublicensable, royalty-free, fully paid-up patent license to make, have made,
use, sell, offer to sell, import, export, and otherwise transfer your
contribution and this project.

### Moral Rights

To the fullest extent permitted by law, you waive, and agree not to assert, any
moral rights, rights of attribution, rights of integrity, or similar rights in
your contribution against Dafdef, inc., its affiliates, successors, assigns,
customers, users, licensees, and sublicensees.

### Relicensing And Commercial Use

Dafdef, inc. may use, license, sublicense, relicense, commercialize, sell, host,
distribute, or otherwise exploit your contribution without restriction,
including under licenses different from this repository's current license,
without compensation or further approval.

### No Compensation, Equity, Or Ownership Rights

Contributing to this repository is voluntary unless you have a separate written
agreement signed by Dafdef, inc. Your contribution does not entitle you to any
money, fees, royalties, revenue share, profit share, bounty, reimbursement,
salary, wages, consulting fees, equity, stock, stock options, tokens, ownership
interest, voting rights, governance rights, board rights, founder status,
employment relationship, contractor relationship, partnership, joint venture, or
other financial or ownership interest in Dafdef, inc., OpenPhone, or any related
product, company, service, asset, or project.

No statement, merge, commit, issue discussion, roadmap discussion, repository
access, title, role, credit, or collaboration creates any right to compensation
or ownership unless it is documented in a separate written agreement signed by
Dafdef, inc.

### No Revocation

This agreement is a condition of contribution. Your grants, assignments,
licenses, waivers, and promises are irrevocable and survive withdrawal of a pull
request, closure of an issue, removal of repository access, termination of your
relationship with this project, and termination of your use of this project.

## Contributor Representations

By contributing, you represent and warrant that:

- your contribution is your original work, or you have all rights required to
  submit it under these terms;
- your contribution does not violate any third-party intellectual property,
  privacy, confidentiality, publicity, contractual, employment, open-source, or
  other rights;
- your contribution does not include code copied from another project unless
  you clearly identify the source and license and Dafdef, inc. explicitly
  approves it before merge;
- you have not included secrets, credentials, private keys, tokens, passwords,
  personal data, customer data, private code, proprietary materials, or anything
  you are not allowed to disclose;
- if your employer, client, school, or another organization may own or control
  rights in your work, you have permission to contribute and to grant the rights
  described here, or that organization has waived those rights;
- you are legally able to agree to these terms.

## Contribution Rules

- Keep pull requests focused. One bug fix, feature, or documentation change per
  PR.
- Do not include unrelated formatting churn or large generated diffs.
- Do not commit secrets, production credentials, local databases, logs, user
  data, screenshots with private information, or machine-specific config.
- Do not add third-party code, fonts, images, sounds, datasets, vendor blobs,
  generated code, or copied materials without calling out the source and license
  in the PR.
- Do not weaken auth, privacy, security, installer integrity, update checks,
  rate limits, data minimization, or licensing controls without explicit
  approval.

## CI Ladder

CI runs in three tiers. Only the first tier runs automatically on fork PRs;
the heavier tiers need maintainer involvement.

1. **Automatic on every PR** (`ci.yml`, ~10 minutes): docs-site build,
   `./scripts/check.sh` (required files, JSON validity, schema
   cross-consistency, runtime protocol validation, broker smoke test, Node
   contract tests, assistant Java compile check), and `git diff --check`.
   Run `./scripts/check.sh` locally before pushing — it is the same check.
2. **Maintainer-triggered** (`gcp-lab.yml`): a maintainer applies the
   `run-gcp-lab` label to run the GCP emulator smoke lab (~30–60 minutes).
   Ask for a lab run in a PR comment when your change affects the image,
   overlay, patches, or on-device behavior.
3. **Release and nightly only**: `emulator.yml` (self-hosted arm64 emulator
   smoke) and `eval.yml` (nightly on-device trajectory smokes and benchmark).
   These do not run on fork PRs.

Reviews are best-effort. If tier 1 is green and you need a lab run or a
review, comment on the PR.

The milestone tracks and current priorities are in [ROADMAP.md](../ROADMAP.md).

## Questions

For licensing, commercial use, or contribution questions, contact support@secondly.com.

## Third-Party And GPL Materials

Do not submit third-party proprietary code, vendor blobs, Google apps, Google
Mobile Services, restricted device materials, signing keys, private firmware,
or other restricted materials to this repository.

GPL-covered contributions must remain under the GPL and must satisfy GPL source
obligations. OpenPhone does not add non-commercial restrictions to GPL-covered
materials. If your contribution touches GPL-covered files, clearly identify that
in the pull request.
