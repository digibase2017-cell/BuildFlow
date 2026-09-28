-- Upgrade existing local Lead statuses to the six approved Sale states.
BEGIN;
ALTER TABLE public.leads DROP CONSTRAINT leads_status_check;
ALTER TABLE public.leads ALTER COLUMN status SET DEFAULT 'Mới';
UPDATE public.leads SET status=CASE status
  WHEN 'Mới tiếp nhận' THEN 'Mới'
  WHEN 'Đã liên hệ' THEN 'Đang chăm sóc'
  WHEN 'Đàm phán' THEN 'Đã hẹn gặp'
  WHEN 'Đã gửi báo giá' THEN 'Đã báo giá'
  ELSE status END
WHERE status IN ('Mới tiếp nhận','Đã liên hệ','Đàm phán','Đã gửi báo giá');
ALTER TABLE public.leads ADD CONSTRAINT leads_status_check CHECK (status IN
  ('Mới','Đang chăm sóc','Đã hẹn gặp','Đã báo giá','Thành công','Thất bại'));
COMMIT;
