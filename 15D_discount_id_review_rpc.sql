CREATE OR REPLACE FUNCTION public.review_discount_id_submission(p_submission_id bigint,p_decision text,p_admin_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_role text; v_sub public.discount_id_submissions%ROWTYPE; v_booking public.bookings%ROWTYPE; v_title text; v_message text;
BEGIN
 v_role:=public.current_user_role();
 IF COALESCE(v_role,'') NOT IN ('admin','super_admin') THEN RAISE EXCEPTION 'Only Admin or Super Admin can review discount IDs.'; END IF;
 IF p_decision NOT IN ('approved','rejected') THEN RAISE EXCEPTION 'Decision must be approved or rejected.'; END IF;
 SELECT * INTO v_sub FROM public.discount_id_submissions WHERE discount_submission_id=p_submission_id FOR UPDATE;
 IF NOT FOUND OR v_sub.status<>'pending_review' THEN RAISE EXCEPTION 'Pending ID submission not found.'; END IF;
 SELECT * INTO v_booking FROM public.bookings WHERE booking_id=v_sub.booking_id FOR UPDATE;
 UPDATE public.discount_id_submissions SET status=p_decision,admin_note=NULLIF(btrim(p_admin_note),''),reviewed_at=now(),reviewed_by=auth.uid(),notification_sent_at=now() WHERE discount_submission_id=p_submission_id;
 IF p_decision='approved' THEN
   UPDATE public.passengers SET passenger_type=v_sub.claimed_type WHERE passenger_id=v_sub.passenger_id;
   v_title:='Discount ID approved';
   v_message:='Your '||upper(v_sub.claimed_type)||' ID for booking '||v_booking.booking_reference||' was approved. Your 20% discount is applied. You have 10 minutes from this notification to upload your payment receipt.';
 ELSE
   UPDATE public.passengers SET passenger_type='regular' WHERE passenger_id=v_sub.passenger_id;
   v_title:='Discount ID rejected';
   v_message:='Your discount ID for booking '||v_booking.booking_reference||' was rejected. Your passenger type is now Regular (no discount). Your 10-minute payment countdown starts now. '||COALESCE(NULLIF(btrim(p_admin_note),''),'Please proceed to payment.');
 END IF;
 -- A booking becomes payable after its final outstanding discount claim has been decided.
 IF NOT EXISTS (SELECT 1 FROM public.discount_id_submissions d WHERE d.booking_id=v_sub.booking_id AND d.status='pending_review') THEN
   UPDATE public.bookings SET booking_status='pending_payment',payment_deadline_at=now()+interval '10 minutes' WHERE booking_id=v_sub.booking_id AND booking_status='pending_discount_verification';
 END IF;
 INSERT INTO public.user_notifications(user_id,booking_id,title,message,notification_type) VALUES(v_sub.user_id,v_sub.booking_id,v_title,v_message,CASE WHEN p_decision='approved' THEN 'success' ELSE 'warning' END);
 RETURN jsonb_build_object('success',true,'decision',p_decision,'booking_reference',v_booking.booking_reference);
END; $$;
REVOKE ALL ON FUNCTION public.review_discount_id_submission(bigint,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.review_discount_id_submission(bigint,text,text) TO authenticated;
