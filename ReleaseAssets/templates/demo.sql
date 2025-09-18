-- demo.sql
-- Write placeholders {{Org-ID}} and {{Acct-ID}} (if needed), exactly as stated. Any other placeholders can use whatever text you want inside double curly brackets:
SELECT <you_queries_here...>;



---|-----------------**- Field Name Placeholders Demo -**------------------------------|
{{Org-ID}}
{{Acct-ID}}
{{Date}}
{{sig-id}}
{{o-id}}
{{clusterName}}


---|-----------------**- Demo Query -**------------------------------|
-- Example template with placeholders
SELECT * FROM `{{Org-id}}`.`_audited_events`
WHERE `resourceId` = '{{sig-id}}'
ORDER BY createdAt DESC;
