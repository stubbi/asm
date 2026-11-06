# Sponsorship operations

The public offer is [the sponsorship page](../site/sponsors.html).
The monthly funding target is USD 100,000.
It is a target, not an amount received or a forecast.

## Purpose and boundaries

Sponsors fund paid maintenance, infrastructure, security work, and public evidence.
This follows the brand principles of dependable reuse, resource care, and trust through evidence.
Recognition and bounded briefings are the benefits.
Sponsorship does not change package ranking, publication rules, security checks, or technical conclusions.
Commissioned engineering and support need separate agreements.

## Contact and payments

GitHub approval for `stubbi` was pending on 7 November 2026.
The dashboard profile and five monthly tiers are configured.
The public page therefore uses email enquiries, not an inactive checkout.
The recipient is the public email address on the maintainer's GitHub profile.
Every tier link supplies its amount and tier in the email subject.
The page also shows the address for people without a configured email application.
No form collects or stores personal data on asm.build.

The repository Sponsor button uses the page as its custom funding route.
Do not replace this route with a GitHub checkout until the listing and correct tiers are published.

The following tier IDs were confirmed in the authenticated GitHub dashboard:

| Monthly tier | USD | GitHub tier ID |
| --- | --- | --- |
| Individual | 10 | 678972 |
| Individual | 25 | 678973 |
| Individual | 100 | 678974 |
| Company | 500 | 678975 |
| Core | 2,000 | 678976 |

Their checkout URL format is `https://github.com/sponsors/stubbi/sponsorships?tier_id=ID`.
These are activation records, not a claim that the pending account can receive payments.
No Principal or Lead checkout tier is published.
The profile describes the USD 100,000 target without enabling disclosure of actual monthly income.

### Activate GitHub Sponsors

1. Open [GitHub Sponsors accounts](https://github.com/sponsors/accounts).
2. Complete the account, identity, tax, payout, and agreement steps with GitHub.
3. Confirm that the configured Core and Company tiers match the public offer.
4. Confirm the individual tiers at USD 10, USD 25, and USD 100.
5. Compare the tier descriptions and welcome messages with the public terms.
6. Check each tier through its public checkout before changing the website links.
7. Replace the corresponding email links with the verified checkout URLs.
8. Retain the email route as a fallback.
9. Update the page and README payment wording after activation.

Keep the repository's custom route to the sponsorship page.
It provides the full offer and the contact-first route for limited tiers.

Keep Principal and Lead sponsorships contact-first.
An open recurring payment does not reserve a limited position or establish an annual agreement.
Do not promise automatic slot enforcement from a static page or payment platform.

## Accept and fulfil a sponsorship

1. Check the tier, requested start date, and affiliated company identity.
2. Check existing agreements before reserving a Principal or Lead position.
3. Agree the term, renewal, cancellation, payment schedule, and recognition permission.
4. Obtain the approved name, website, and applicable logo.
5. Confirm payment before starting paid recognition.
6. Record the agreement, payment status, dates, and fulfilment privately.
7. Publish only the approved recognition.
8. Schedule the applicable briefings and report dates.
9. Remove current recognition when the paid term ends.

Keep at most four Principal and eight Lead sponsors in overlapping terms.
Count affiliated companies together when applying these limits.
Core and Company have no fixed sponsor limit.
Never derive availability from a public logo list: a sponsor can decline public recognition.
Confirm capacity before an agreement; the page makes no live availability claim.

Use a linked homepage logo for Principal sponsors only, after package discovery.
Use README logos for Principal and Lead sponsors, after the primary instructions.
Use README names for Core sponsors.
Use linked names on this page for Company sponsors and approved individual supporters.
Do not add empty logo placeholders or describe an unconfirmed company as a sponsor.
Use `rel="sponsored"` on paid website links.
Active corporate sponsors may use [the support badge](../site/supports-asm.svg) during the paid term.
The badge does not grant product endorsement.

Principal programmes receive quarterly budget, work, evidence, delay, and risk reports.
Publish an annual funding report with approved corporate recognition.
Preserve failed and inconclusive results.
Do not describe donated services or unsigned commitments as recurring cash revenue.

## Validation and publication

Run the site checks before publication:

```sh
python3 -m unittest discover -s tests -p 'test_site.py' -v
node --test tests/site.test.cjs
python3 tools/build_site.py --output .pages
```

Check the built page in a browser at desktop and narrow widths.
Check keyboard focus, the badge download, page links, and all enquiry destinations.
Check the visible address as the fallback for an unavailable email application.
Do not send a test enquiry or make a payment during verification.
After publication, check the public page and each payment route again.
The existing Pages workflow runs full repository checks and artifact verification before deployment.
