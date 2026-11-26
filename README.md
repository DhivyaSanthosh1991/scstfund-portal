# TN SC/ST Startup Fund — application portal

Two pages on one Supabase database:

| Page | Who uses it | Path |
|---|---|---|
| Application form | Startups (public) | `/` |
| Review pipeline | StartupTN fund team | `/review/` |

```
scst-fund-portal/
├── supabase/schema.sql   tables, access rules, file storage, submit check
├── web/index.html        public application form
├── web/review/index.html staff review pipeline (SOP phases 1–3)
├── web/config.js         your Supabase URL and public key
├── web/assets/base.css   shared styles
└── netlify.toml          hosting settings and security headers
```

## How it works

**Applicants** sign in with a 6-digit code sent to their email (no password), fill in eight sections, and can save and return. Every change saves automatically. They upload documents as PDF, JPG or PNG (up to 10 MB each).

**Eligibility is checked twice**: live on the form, and again on the server when they press Submit. The server refuses the submission unless:

- SC/ST founders together hold **more than 50%** of equity (exactly 50% is refused)
- founder shareholding does not add up to more than 100%
- at least one SC/ST founder is marked as holding operational and management control, and the applicant has described how control is held
- every SC/ST founder has a community certificate attached
- pitch deck, certificate of incorporation and cap table are attached
- all required fields, declarations and both consents are complete

On submit the application gets a number (`SCST-2026-0001`, …), is locked against further edits, and appears in the review pipeline at **Phase 1 · Validation**.

**Staff** sign in the same way, but only email addresses on the `staff` list get in. Staff see the submission read-only, verify eligibility (certificates, equity against the cap table, control), and move it through the SOP:

- Phase 1: validation → SME pitch → recommend for BDD, refer to MSME Dept, or reject. BDD needs an early or growth stage startup and all four pitch scores.
- Phase 2: BDD partner prepares the IM → IC (recommend to PSC or reject) → PSC (approve or reject)
- Phase 3: term sheet → LDD & FDD → SSHA → fund release
- IC or PSC can reject at any point from Phase 2.

Vendor handoffs use **Copy packet** buttons that put the application summary on the clipboard to email to the BDD or LDD partner. Vendors never get access to the system. Staff attach the IM, term sheet, LDD/FDD reports and SSHA as PDFs.

**What each person can see**

| | Applicant | Other applicants | Staff |
|---|---|---|---|
| Own draft | edit | — | — |
| Own submitted application | read | — | read |
| Review notes, scores, decisions | — | — | read and edit |
| Staff documents (IM, SSHA, …) | — | — | read and add |

Staff cannot change what the applicant submitted. If two staff members edit the same application at once, the second save is refused and the page reloads the latest version instead of overwriting.

## Setup

### 1. Supabase project
1. Create a project at supabase.com. Choose the **Mumbai (ap-south-1)** region so data stays in India.
2. Open **SQL Editor → New query**, paste all of `supabase/schema.sql`, and run it. It is safe to run again later.
3. **Authentication → Providers → Email**: keep Email enabled.
4. **Authentication → Email templates → Magic link**: the email must contain the code. Put `{{ .Token }}` in the body, for example:
   `Your TN SC/ST Startup Fund sign-in code is {{ .Token }}. It expires in 1 hour.`
5. **Custom SMTP (required before launch)**: Supabase's built-in email sender only allows a few emails per hour. Under **Project Settings → Authentication → SMTP**, connect StartupTN's mail server or a sending service.
6. **Project Settings → API**: copy the Project URL and the `anon` public key into `web/config.js`. Never put the `service_role` key in the website.

### 2. Add staff
Staff accounts are created by an admin; the review page never creates new users.

1. **Authentication → Users → Add user**, enter the person's work email.
2. In **SQL Editor**, run:
   ```sql
   insert into public.staff (user_id, email, full_name, role)
   select id, email, 'Full Name', 'admin' from auth.users where email = 'name@startuptn.in';
   ```
   Use `role = 'reviewer'` for everyone except admins. Admins can also reopen closed applications.

To remove access: `delete from public.staff where email = 'name@startuptn.in';`

### 3. Deploy on Netlify
1. Put this folder in a GitHub repository, then in Netlify choose **Add new site → Import an existing project**. `netlify.toml` sets the publish folder. (Or drag the `web` folder onto Netlify's deploy page.)
2. Add a domain, for example a `startuptn.in` subdomain.
3. In Supabase **Authentication → URL Configuration**, set the Site URL to that domain.

## Before going live
- Have legal review the four declarations and consents on the last section of the form, and publish a privacy notice. Community certificates are sensitive personal data under the DPDP Act, 2023.
- Confirm the eligible entity types and any other scheme rules. Only the more-than-50% equity and control rules are enforced.
- Turn on CAPTCHA under **Authentication → Bot and abuse protection**. The form will then need a CAPTCHA widget added to the sign-in step; ask me to add it.
- Decide how long applications and documents are kept, and enable database backups (Supabase Pro plan).
- Run one full test application end to end with real email.

## Tests that were run
- **Database (27 checks)** in a local Postgres with the access rules on: applicants cannot set their own status or number, cannot edit after submitting, cannot see each other's data or files, cannot upload into another folder or the staff folder, and cannot see review data or staff documents. Submission is refused at 30% and at exactly 50% SC/ST equity and when control sits only with a non-SC/ST founder, and accepted at 55% combined (SC + ST). Staff can move stages, log activity and upload, but cannot alter the applicant's answers.
- **Pages (30 checks)** in a headless browser against a stand-in database: autosave, the live equity meter, founder certificates, repeating rows, the submit checklist, staff validation and stage moves, the MSME referral, and refusal of a stale save.

Not yet tested against a real Supabase project: email delivery, file uploads to the real bucket, and Supabase's own row filters.

## Later: handing over to the StartupTN portal team
`supabase/schema.sql` is the specification: field list, validation rules and access rules. If the portal team builds the public form on the same tables, the review pipeline keeps working unchanged.

To rerun them: `cd tests && npm install && npm test`.

## Autofill from uploaded documents

When an applicant uploads a pitch deck, certificate of incorporation, shareholding pattern or a founder's
community certificate, the form calls the `extract-document` Edge Function
(`supabase/functions/extract-document`). It downloads the file as the applicant, asks Claude to read it, and the
form fills **only empty fields**, highlights them, and flags mismatches (name on certificate vs founder, SC/ST
category vs selection, form vs certificate legal name). It never fills community, "holds control" or any declaration.

- Secret: `ANTHROPIC_API_KEY` (Supabase → Edge Functions → Secrets). Never put it in `config.js`.
- Limit: 30 reads per applicant per 24 h (table `extraction_log`).
- Staff must still verify certificates by eye; the reader checks nothing about authenticity.
- The privacy notice must say uploaded files are processed by an AI service (Anthropic).
