-- Weekly email: every Monday 9:00 AM India time (03:30 UTC).
-- First enable the pg_cron and pg_net extensions (Dashboard -> Database -> Extensions).
-- Replace YOUR-PROJECT-REF and YOUR-CRON-SECRET (the same value you set as the CRON_SECRET secret).
select cron.schedule(
  'umang-weekly-report',
  '30 3 * * 1',
  $$select net.http_post(
      url := 'https://YOUR-PROJECT-REF.supabase.co/functions/v1/weekly-report',
      headers := '{"Content-Type":"application/json","x-cron-secret":"YOUR-CRON-SECRET"}'::jsonb,
      body := '{"days":7}'::jsonb
  )$$
);
