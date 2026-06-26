-- 1. Базовый CTE: только первые сессии для каждой группы (rn = 1)
WITH first_sessions AS (
    SELECT 
        session_id,
        customer_id,
        experiment_group,
        timestamp AS session_start,
        ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY timestamp) AS rn
    FROM events
    WHERE campaign_id = 1
      AND experiment_group IN ('Control', 'Variant_A')
      AND device_type IS NOT NULL
      AND device_type != ''
),

-- 2. Только первые сессии (очищенные)
clean_sessions AS (
    SELECT 
        session_id,
        customer_id,
        experiment_group,
        session_start
    FROM first_sessions
    WHERE rn = 1
),

-- 3. События в этих сессиях (для воронки)
session_events AS (
    SELECT 
        cs.session_id,
        cs.customer_id,
        cs.experiment_group,
        cs.session_start,
        MAX(CASE WHEN e.event_type = 'view' THEN 1 ELSE 0 END) AS has_view,
        MAX(CASE WHEN e.event_type = 'add_to_cart' THEN 1 ELSE 0 END) AS has_cart,
        MAX(CASE WHEN e.event_type = 'purchase' THEN 1 ELSE 0 END) AS has_purchase
    FROM clean_sessions cs
    LEFT JOIN events e ON cs.session_id = e.session_id
    GROUP BY cs.session_id, cs.customer_id, cs.experiment_group, cs.session_start
),

-- 4. Выручка по пользователям (через customer_id и дату)
user_revenue AS (
    SELECT 
        cs.customer_id,
        cs.experiment_group,
        DATE(cs.session_start) AS session_date,
        COALESCE(SUM(t.gross_revenue), 0) AS total_revenue
    FROM clean_sessions cs
    LEFT JOIN transactions t 
        ON cs.customer_id = t.customer_id 
        AND DATE(t.timestamp) = DATE(cs.session_start)  -- связь по дате и пользователю
    GROUP BY cs.customer_id, cs.experiment_group, DATE(cs.session_start)
),

-- 5. Retention: возврат пользователей через 7 и 30 дней
retention_data AS (
    SELECT 
        cs.customer_id,
        cs.experiment_group,
        cs.session_start AS first_event_date,
        MIN(e.timestamp) AS next_event_date
    FROM clean_sessions cs
    LEFT JOIN events e ON cs.customer_id = e.customer_id 
        AND e.timestamp > cs.session_start
        AND e.campaign_id = 1
    GROUP BY cs.customer_id, cs.experiment_group, cs.session_start
)

-- 6. Финальный SELECT (адаптированный)
SELECT 
    se.experiment_group,
    -- Конверсия
    COUNT(DISTINCT se.session_id) AS total_sessions,
    SUM(se.has_purchase) AS purchases,
    ROUND(100.0 * SUM(se.has_purchase) / COUNT(DISTINCT se.session_id), 2) AS conversion_rate_pct,
    
    -- Воронка
    SUM(se.has_view) AS views,
    SUM(se.has_cart) AS carts,
    ROUND(100.0 * SUM(se.has_cart) / NULLIF(SUM(se.has_view), 0), 2) AS view_to_cart_pct,
    ROUND(100.0 * SUM(se.has_purchase) / NULLIF(SUM(se.has_cart), 0), 2) AS cart_to_purchase_pct,
    
    -- RPV (выручка на пользователя, а не на сессию)
    ROUND(AVG(ur.total_revenue), 2) AS avg_revenue_per_user,
    
    -- Retention (7 и 30 дней)
    COUNT(DISTINCT rd.customer_id) AS total_users,
    COUNT(DISTINCT CASE 
        WHEN rd.next_event_date <= DATE(rd.first_event_date, '+7 days') 
        THEN rd.customer_id END) AS retained_7d,
    ROUND(100.0 * COUNT(DISTINCT CASE 
        WHEN rd.next_event_date <= DATE(rd.first_event_date, '+7 days') 
        THEN rd.customer_id END) / COUNT(DISTINCT rd.customer_id), 2) AS retention_7d_pct,
    COUNT(DISTINCT CASE 
        WHEN rd.next_event_date <= DATE(rd.first_event_date, '+30 days') 
        THEN rd.customer_id END) AS retained_30d,
    ROUND(100.0 * COUNT(DISTINCT CASE 
        WHEN rd.next_event_date <= DATE(rd.first_event_date, '+30 days') 
        THEN rd.customer_id END) / COUNT(DISTINCT rd.customer_id), 2) AS retention_30d_pct

FROM session_events se
LEFT JOIN user_revenue ur 
    ON se.customer_id = ur.customer_id 
    AND DATE(se.session_start) = ur.session_date
LEFT JOIN retention_data rd 
    ON se.customer_id = rd.customer_id 
    AND se.experiment_group = rd.experiment_group
GROUP BY se.experiment_group;