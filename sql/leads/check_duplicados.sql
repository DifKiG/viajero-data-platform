SELECT lead_id, COUNT(*)
FROM staging.leads_raw
GROUP BY lead_id
HAVING COUNT(*) > 1;

