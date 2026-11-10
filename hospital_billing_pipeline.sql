--- Bronze table code
CREATE OR REFRESH STREAMING TABLE pl_bronze_hospital_billing AS
SELECT
    *,
    _metadata.file_name AS source_file,
    current_timestamp() AS loaded_at
FROM STREAM read_files(
    '/Volumes/healthcare_catalog/billing/raw_files/',
    format => 'csv',
    header => true
);

--- Silver – Clean records
CREATE OR REFRESH MATERIALIZED VIEW pl_silver_billing_clean AS
SELECT
    bill_id,
    visit_id,
    patient_id,
    INITCAP(TRIM(patient_gender)) AS patient_gender,
    patient_age,
    visit_date,
    INITCAP(TRIM(visit_type)) AS visit_type,
    COALESCE(INITCAP(TRIM(department)), 'Unknown') AS department,
    INITCAP(TRIM(doctor_name)) AS doctor_name,
    INITCAP(TRIM(service_category)) AS service_category,
    INITCAP(TRIM(service_name)) AS service_name,
    INITCAP(TRIM(hospital_branch)) AS hospital_branch,
    INITCAP(TRIM(city)) AS city,
    INITCAP(TRIM(region)) AS region,
    COALESCE(INITCAP(TRIM(payer_type)), 'Unknown') AS payer_type,
    quantity,
    unit_price,
    COALESCE(total_amount, quantity * unit_price) AS total_amount,
    insurance_amount,
    INITCAP(TRIM(payment_status)) AS payment_status,
    source_file,
    loaded_at
FROM (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY bill_id
            ORDER BY visit_date DESC
        ) AS rn
    FROM pl_bronze_hospital_billing
)
WHERE rn = 1
  AND quantity > 0
  AND unit_price >= 0;

--- Silver – Rejected records
CREATE OR REFRESH MATERIALIZED VIEW pl_silver_billing_rejected AS
SELECT *,
    CASE
        WHEN quantity <= 0 THEN 'Quantity is zero or negative'
        WHEN unit_price < 0 THEN 'Unit price is negative'
    END AS reject_reason
FROM pl_bronze_hospital_billing
WHERE quantity <= 0 OR unit_price < 0;

--- 4 Gold tables:
-- Monthly Revenue
CREATE OR REFRESH MATERIALIZED VIEW pl_gold_monthly_revenue AS
SELECT
    DATE_TRUNC('MONTH', visit_date) AS visit_month,
    COUNT(DISTINCT visit_id) AS visits,
    SUM(total_amount) AS total_revenue,
    SUM(insurance_amount) AS insurance_amount
FROM pl_silver_billing_clean
GROUP BY DATE_TRUNC('MONTH', visit_date);

-- Department Summary
CREATE OR REFRESH MATERIALIZED VIEW pl_gold_department_summary AS
SELECT
    department,
    COUNT(*) AS total_bills,
    SUM(total_amount) AS total_revenue,
    AVG(total_amount) AS average_bill_amount
FROM pl_silver_billing_clean
GROUP BY department;

-- Branch Summary
CREATE OR REFRESH MATERIALIZED VIEW pl_gold_branch_summary AS
SELECT
    hospital_branch,
    city,
    COUNT(*) AS total_bills,
    SUM(total_amount) AS total_revenue
FROM pl_silver_billing_clean
GROUP BY hospital_branch, city;

-- Payer Summary
CREATE OR REFRESH MATERIALIZED VIEW pl_gold_payer_summary AS
SELECT
    payer_type,
    COUNT(*) AS total_bills,
    SUM(total_amount) AS total_revenue,
    SUM(insurance_amount) AS total_insurance_amount
FROM pl_silver_billing_clean
GROUP BY payer_type;

--- final Gold table – Data Quality
CREATE OR REFRESH MATERIALIZED VIEW pl_gold_data_quality AS
SELECT
    (SELECT COUNT(*) FROM pl_bronze_hospital_billing) AS bronze_rows,

    (SELECT COUNT(*) FROM pl_silver_billing_clean) AS clean_rows,

    (SELECT COUNT(*) FROM pl_silver_billing_rejected) AS rejected_rows,

    (SELECT COUNT(*)
     FROM (
         SELECT bill_id
         FROM pl_bronze_hospital_billing
         GROUP BY bill_id
         HAVING COUNT(*) > 1
     )
    ) AS duplicate_bill_ids;
