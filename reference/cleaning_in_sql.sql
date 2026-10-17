/* =====================================================================
   reference/cleaning_in_sql.sql   —   WORKFLOW STEP 7 : CLEAN AND TRANSFORM
   Contoso Profitability
   ---------------------------------------------------------------------
   Step 6 counted what was broken. This file decides what to do about
   each item, and records why.

   The reasons are the deliverable. Most of these decisions could have gone
   the other way, and the ones I got wrong first time are noted.

   Output: clean, typed tables ready for the model.
     stg_*  (raw text)  ->  dim_* / fact_sales  (typed, deduplicated)
   ===================================================================== */

USE ContosoRetail;
GO

SET LANGUAGE us_english;   -- needed so 'Jan','Feb'... parse in style 106
GO


/* =====================================================================
   DECISION REGISTER  —  reproduced in the README
   ---------------------------------------------------------------------
   ISSUE                     ROWS   DECISION                  WHY
   ---------------------------------------------------------------------
   ShippingDays placeholder  4713   -> NULL + IsShippingKnown  Never invent a
                                                               delivery time.
                                                               A flag lets the
                                                               reader see coverage.
   OrderDate non-ISO         1571   Parse all 5 formats        Data is recoverable;
                                                               dropping 1% of rows
                                                               would bias by date.
   PaymentMethod missing     1571   -> NULL                    Keep the row: the
                                                               SALE is still valid,
                                                               only the tender is
                                                               unknown.
   Text case variants        ~1.5%  Map to canonical values    Trim alone is not
                                                               enough: 'M' and
                                                               'MALE' need a MAP.
   Quantity <= 0               16   EXCLUDE                    A sale of zero or
                                                               minus-three units is
                                                               not a transaction.
                                                               0.01% - no bias.
   DiscountPercent > 1          8   EXCLUDE                    Impossible. And the
                                                               money was not
                                                               recalculated for them.
   Duplicate keys (identical)  10   Remove duplicates          Nothing is lost.
   Duplicate keys (conflicting) 5   Survivorship rule          See note below.
   Orphan FKs                  34   Map to 'UNKNOWN' member    NEVER drop silently.
                                                               Revenue stays in the
                                                               totals and stays
                                                               visible.
   Formula breaches          1073   KEEP + flag                You do not know which
                                                               side is wrong. Flag,
                                                               quantify, disclose.
   Negative profit          17425   KEEP - NOT AN ERROR        This is the finding.
   ===================================================================== */


/* =====================================================================
   1.  CLEAN DIMENSIONS
   ===================================================================== */

/* ---------------------------------------------------------------------
   1a. Dim_Product
   ---------------------------------------------------------------------
   SURVIVORSHIP RULE: when one ProductID appears twice with different
   attributes, keep the row whose ProductStatus sorts first alphabetically
   (Active < Clearance < Discontinued < New) — i.e. prefer the record that
   shows the product as currently sellable.

   The rule is arbitrary but deterministic, and stated. With a
   LastModified column I would have used it; this source has none, so I
   had to pick one and write it down rather than let ROW_NUMBER choose
   silently.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dim_product;
GO

WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY ProductID
                              ORDER BY ProductStatus, ListPrice) AS rn
    FROM   stg_Dim_Product
)
SELECT
    ProductID,
    LTRIM(RTRIM(ProductName))                                  AS ProductName,
    CASE UPPER(LTRIM(RTRIM(Category)))
         WHEN 'TECHNOLOGY'      THEN 'Technology'
         WHEN 'FURNITURE'       THEN 'Furniture'
         WHEN 'OFFICE SUPPLIES' THEN 'Office Supplies'
         WHEN 'APPLIANCES'      THEN 'Appliances'
         WHEN 'ACCESSORIES'     THEN 'Accessories'
    END                                                        AS Category,
    LTRIM(RTRIM(SubCategory))                                  AS SubCategory,
    NULLIF(LTRIM(RTRIM(Brand)), '')                            AS Brand,
    TRY_CONVERT(DATE, LaunchDate, 23)                          AS LaunchDate,
    ProductStatus,
    TRY_CAST(StandardCost AS DECIMAL(12,2))                    AS StandardCost,
    TRY_CAST(ListPrice    AS DECIMAL(12,2))                    AS ListPrice,
    CASE WHEN TRY_CAST(StandardCost AS FLOAT) > TRY_CAST(ListPrice AS FLOAT)
         THEN 1 ELSE 0 END                                     AS IsPricedBelowCost
INTO dim_product
FROM ranked
WHERE rn = 1;
GO

-- Add the Unknown member so orphan fact rows have somewhere to point.
INSERT INTO dim_product
      (ProductID, ProductName, Category, SubCategory, Brand, LaunchDate,
       ProductStatus, StandardCost, ListPrice, IsPricedBelowCost)
VALUES ('UNKNOWN','Unknown Product','Unknown','Unknown',NULL,NULL,'Unknown',NULL,NULL,0);
GO


/* ---------------------------------------------------------------------
   1b. Dim_Customer
   ---------------------------------------------------------------------
   SURVIVORSHIP RULE: prefer the record showing the customer as Active
   (Active < Churned < Dormant alphabetically) — the more recent state.

   Age is RECOMPUTED from DateOfBirth rather than trusted. Step 6 found 5
   impossible values (0, negative, >120). Recomputing fixes all five
   without a special case, and AgeGroup is derived so the 24 blanks
   disappear too. Deriving beats imputing whenever the source exists.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dim_customer;
GO

WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY CustomerID
                              ORDER BY CustomerStatus, Segment) AS rn
    FROM   stg_Dim_Customer
),
cleaned AS (
    SELECT
        CustomerID,
        NULLIF(LTRIM(RTRIM(CustomerName)), '')                 AS CustomerName,
        CASE WHEN UPPER(LTRIM(RTRIM(Gender))) IN ('M','MALE')   THEN 'Male'
             WHEN UPPER(LTRIM(RTRIM(Gender))) IN ('F','FEMALE') THEN 'Female'
        END                                                    AS Gender,
        TRY_CONVERT(DATE, DateOfBirth, 23)                     AS DateOfBirth,
        CASE UPPER(LTRIM(RTRIM(Segment)))
             WHEN 'CONSUMER'       THEN 'Consumer'
             WHEN 'SMALL BUSINESS' THEN 'Small Business'
             WHEN 'CORPORATE'      THEN 'Corporate'
             WHEN 'ENTERPRISE'     THEN 'Enterprise'
        END                                                    AS Segment,
        TRY_CONVERT(DATE, JoinDate, 23)                        AS JoinDate,
        NULLIF(LTRIM(RTRIM(City)),  '')                        AS City,
        NULLIF(LTRIM(RTRIM(State)), '')                        AS State,
        RegionID,
        CustomerStatus
    FROM ranked WHERE rn = 1
)
SELECT c.CustomerID, c.CustomerName, c.Gender, c.DateOfBirth,
       DATEDIFF(YEAR, c.DateOfBirth, '2025-12-31')             AS Age,
       CASE
         WHEN c.DateOfBirth IS NULL                             THEN 'Unknown'
         WHEN DATEDIFF(YEAR, c.DateOfBirth, '2025-12-31') <= 24 THEN '18-24'
         WHEN DATEDIFF(YEAR, c.DateOfBirth, '2025-12-31') <= 34 THEN '25-34'
         WHEN DATEDIFF(YEAR, c.DateOfBirth, '2025-12-31') <= 44 THEN '35-44'
         WHEN DATEDIFF(YEAR, c.DateOfBirth, '2025-12-31') <= 54 THEN '45-54'
         WHEN DATEDIFF(YEAR, c.DateOfBirth, '2025-12-31') <= 64 THEN '55-64'
         ELSE '65+'
       END                                                     AS AgeGroup,
       /*  The NULL guard on the first line is not decoration. Without it,
           DATEDIFF(YEAR, NULL, ...) returns NULL, NULL fails every <=
           comparison, and the row falls through to ELSE '65+'. A customer
           with no date of birth would silently be reported as a pensioner.

           It does not bite on this data (DateOfBirth has no missing values),
           but it is wrong the moment the source changes. A CASE whose ELSE
           catches NULL is a bug waiting for new data.                     */
       c.Segment, c.JoinDate,
       -- City/State blanks are recoverable from the region, not imputed:
       COALESCE(c.City,  r.City)                               AS City,
       COALESCE(c.State, r.State)                              AS State,
       c.RegionID, c.CustomerStatus
INTO   dim_customer
FROM   cleaned c
LEFT   JOIN stg_Dim_Region r ON r.RegionID = c.RegionID;
GO

INSERT INTO dim_customer
      (CustomerID, CustomerName, Gender, DateOfBirth, Age, AgeGroup,
       Segment, JoinDate, City, State, RegionID, CustomerStatus)
VALUES ('UNKNOWN','Unknown Customer',NULL,NULL,NULL,'Unknown',
        'Unknown',NULL,'Unknown','Unknown','UNKNOWN','Unknown');
GO


/* ---------------------------------------------------------------------
   1c. Dim_Region, Dim_Channel, Dim_Date — already clean, just typed
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dim_region;
SELECT RegionID, Region, Zone, State, City, Country
INTO   dim_region FROM stg_Dim_Region;
INSERT INTO dim_region VALUES ('UNKNOWN','Unknown','Unknown','Unknown','Unknown','Unknown');
GO

DROP TABLE IF EXISTS dim_channel;
SELECT ChannelID, Channel, ChannelType INTO dim_channel FROM stg_Dim_Channel;
GO

DROP TABLE IF EXISTS dim_date;
SELECT TRY_CONVERT(DATE,[Date],23)        AS [Date],
       TRY_CAST([Year] AS INT)            AS [Year],
       Quarter,
       TRY_CAST(QuarterNumber AS INT)     AS QuarterNumber,
       [Month],
       TRY_CAST(MonthNumber AS INT)       AS MonthNumber,
       YearMonth,
       TRY_CAST(WeekNumber AS INT)        AS WeekNumber,
       TRY_CAST([Day] AS INT)             AS [Day],
       DayName,
       TRY_CAST(DayOfWeekNumber AS INT)   AS DayOfWeekNumber,
       CASE WHEN IsWeekend='TRUE' THEN 1 ELSE 0 END AS IsWeekend,
       CASE WHEN IsHoliday='TRUE' THEN 1 ELSE 0 END AS IsHoliday
INTO   dim_date FROM stg_Dim_Date;
GO

DROP TABLE IF EXISTS dim_userregion;
SELECT UserPrincipalName, UserName, RoleName, Zone, Region, RegionID
INTO   dim_userregion FROM stg_Dim_UserRegion;
GO


/* =====================================================================
   2.  CLEAN FACT TABLE
   ===================================================================== */

/* ---------------------------------------------------------------------
   THE DATE PARSER

   COALESCE tries each format in turn and takes the first that succeeds.
   It works because the formats are MUTUALLY EXCLUSIVE in this data:
   the slash dates only ever use days above 12, so "20/01/2022" parses
   under style 103 (dd/mm) and FAILS under 101 (mm/dd), and vice versa.
   Exactly one branch succeeds per row.

   Style codes:  23 = yyyy-mm-dd    103 = dd/mm/yyyy
                101 = mm/dd/yyyy    106 = dd mon yyyy    111 = yyyy/mm/dd

   Style 106 wants spaces, so '20-Jan-2022' is converted to '20 Jan 2022'
   first. That REPLACE is safe here only because ISO is tried first.

   ⚠️  TRY_CONVERT returns NULL on failure instead of aborting the query.
       Use it, then CHECK THE NULL COUNT afterwards. Silently converting
       and never verifying is how 1% of a table quietly disappears.
   --------------------------------------------------------------------- */

DROP TABLE IF EXISTS fact_sales;
GO

SELECT
    f.OrderID,
    f.OrderLineID,

    COALESCE( TRY_CONVERT(DATE, f.OrderDate, 23),
              TRY_CONVERT(DATE, f.OrderDate, 103),
              TRY_CONVERT(DATE, f.OrderDate, 101),
              TRY_CONVERT(DATE, REPLACE(f.OrderDate,'-',' '), 106),
              TRY_CONVERT(DATE, f.OrderDate, 111) )            AS OrderDate,

    -- Orphan keys -> the Unknown member. Never dropped, always visible.
    CASE WHEN c.CustomerID IS NULL THEN 'UNKNOWN' ELSE f.CustomerID END AS CustomerID,
    CASE WHEN p.ProductID  IS NULL THEN 'UNKNOWN' ELSE f.ProductID  END AS ProductID,
    CASE WHEN r.RegionID   IS NULL THEN 'UNKNOWN' ELSE f.RegionID   END AS RegionID,
    f.ChannelID,

    TRY_CAST(f.Quantity        AS INT)            AS Quantity,
    TRY_CAST(f.UnitPrice       AS DECIMAL(12,2))  AS UnitPrice,
    TRY_CAST(f.DiscountPercent AS DECIMAL(5,4))   AS DiscountPercent,
    TRY_CAST(f.SalesAmount     AS DECIMAL(14,2))  AS SalesAmount,
    TRY_CAST(f.CostAmount      AS DECIMAL(14,2))  AS CostAmount,
    TRY_CAST(f.ProfitAmount    AS DECIMAL(14,2))  AS ProfitAmount,

    CASE UPPER(LTRIM(RTRIM(f.PaymentMethod)))
         WHEN 'CREDIT CARD' THEN 'Credit Card'
         WHEN 'DEBIT CARD'  THEN 'Debit Card'
         WHEN 'UPI'         THEN 'UPI'
         WHEN 'CASH'        THEN 'Cash'
         WHEN 'NET BANKING' THEN 'Net Banking'
         WHEN 'WALLET'      THEN 'Wallet'
    END                                           AS PaymentMethod,

    CASE UPPER(LTRIM(RTRIM(f.OrderStatus)))
         WHEN 'COMPLETED' THEN 'Completed'
         WHEN 'RETURNED'  THEN 'Returned'
         WHEN 'CANCELLED' THEN 'Cancelled'
         WHEN 'CANCELED'  THEN 'Cancelled'   -- US spelling, same thing
    END                                           AS OrderStatus,

    -- ShippingDays: placeholders become NULL, and a flag records coverage
    TRY_CAST(f.ShippingDays AS INT)               AS ShippingDays,
    CASE WHEN TRY_CAST(f.ShippingDays AS INT) IS NULL THEN 0 ELSE 1 END AS IsShippingKnown,

    -- Derived columns for the analysis
    CASE WHEN TRY_CAST(f.ProfitAmount AS FLOAT) < 0 THEN 1 ELSE 0 END   AS LossFlag,

    CASE WHEN TRY_CAST(f.DiscountPercent AS FLOAT) =  0    THEN '0%'
         WHEN TRY_CAST(f.DiscountPercent AS FLOAT) <= 0.10 THEN '0-10%'
         WHEN TRY_CAST(f.DiscountPercent AS FLOAT) <= 0.20 THEN '10-20%'
         WHEN TRY_CAST(f.DiscountPercent AS FLOAT) <= 0.30 THEN '20-30%'
         ELSE '30-40%' END                        AS DiscountBand,

    -- Flag both rules, correct neither. I do not know which side is wrong,
    -- so quarantining and quantifying beats guessing.
    CASE WHEN ABS( TRY_CAST(f.SalesAmount AS FLOAT)
                 - ROUND(TRY_CAST(f.Quantity AS FLOAT)*TRY_CAST(f.UnitPrice AS FLOAT)
                        *(1-TRY_CAST(f.DiscountPercent AS FLOAT)),2)) > 0.05
         THEN 1 ELSE 0 END                        AS FailsPricingRule,

    CASE WHEN ABS( (TRY_CAST(f.SalesAmount AS FLOAT) - TRY_CAST(f.CostAmount AS FLOAT))
                 -  TRY_CAST(f.ProfitAmount AS FLOAT) ) > 0.05
         THEN 1 ELSE 0 END                        AS FailsProfitRule

INTO fact_sales
FROM stg_Fact_Sales f
LEFT JOIN (SELECT DISTINCT CustomerID FROM stg_Dim_Customer) c ON c.CustomerID = f.CustomerID
LEFT JOIN (SELECT DISTINCT ProductID  FROM stg_Dim_Product)  p ON p.ProductID  = f.ProductID
LEFT JOIN (SELECT DISTINCT RegionID   FROM stg_Dim_Region)   r ON r.RegionID   = f.RegionID
WHERE TRY_CAST(f.Quantity AS INT) > 0
  AND TRY_CAST(f.DiscountPercent AS FLOAT) BETWEEN 0 AND 1;
GO

/*  ⚠️  NOTE THE  SELECT DISTINCT  IN THOSE THREE JOINS.
    stg_Dim_Customer has 10 duplicate keys and stg_Dim_Product has 5.
    Joining straight to them would MULTIPLY fact rows — 157,092 would
    become more than 157,092 and every revenue figure would inflate.
    DISTINCT on the key collapses that. I missed it on the first run and
    the revenue total came back high with no error anywhere.             */


/* =====================================================================
   3.  VERIFY THE CLEANING WORKED
   ===================================================================== */
SELECT 'fact_sales rows'        AS Check_, COUNT(*) AS Value, 157092 AS Expected FROM fact_sales
UNION ALL SELECT 'distinct orders',  COUNT(DISTINCT OrderID), 73995 FROM fact_sales
UNION ALL SELECT 'unparsed dates',   SUM(CASE WHEN OrderDate    IS NULL THEN 1 ELSE 0 END), 0 FROM fact_sales
UNION ALL SELECT 'unmapped status',  SUM(CASE WHEN OrderStatus  IS NULL THEN 1 ELSE 0 END), 0 FROM fact_sales
UNION ALL SELECT 'distinct status',  COUNT(DISTINCT OrderStatus), 3 FROM fact_sales
UNION ALL SELECT 'shipping known',   SUM(IsShippingKnown), 152379 FROM fact_sales
UNION ALL SELECT 'dim_product rows', COUNT(*), 1401 FROM dim_product
UNION ALL SELECT 'dim_customer rows',COUNT(*), 8001 FROM dim_customer
UNION ALL SELECT 'fails pricing rule', SUM(FailsPricingRule), 700 FROM fact_sales
UNION ALL SELECT 'fails profit rule',  SUM(FailsProfitRule),  349 FROM fact_sales
UNION ALL SELECT 'fails either rule',
       SUM(CASE WHEN FailsPricingRule=1 OR FailsProfitRule=1 THEN 1 ELSE 0 END), 1049
FROM fact_sales
UNION ALL SELECT 'AgeGroup = Unknown', SUM(CASE WHEN AgeGroup='Unknown' THEN 1 ELSE 0 END), 1
FROM dim_customer;
GO

/*  1,049 rows fail at least one money rule out of 157,092 = 0.67%.
    So 99.33% reconciles on BOTH rules. That is the ONLY reconciliation
    figure I quote anywhere - reporting 99.55% (pricing rule alone) would
    be quietly flattering, because it ignores the 349 profit breaches.

    The 'AgeGroup = Unknown' row expects 1: the UNKNOWN dimension member.
    If it ever returns more, a real DateOfBirth went missing upstream and
    the NULL guard above is now earning its keep.                        */
/*  1401 and 8001 include the UNKNOWN member (1400 + 1, 8000 + 1).

    157,116 raw - 24 excluded (16 bad quantity + 8 bad discount) = 157,092.
    0.015% removed. The count goes in the write-up - "I excluded 24 rows
    and here is why" reads better than a total that quietly does not match
    the source.                                                          */

-- Referential integrity must now be perfect.
SELECT
  (SELECT COUNT(*) FROM fact_sales f WHERE NOT EXISTS
      (SELECT 1 FROM dim_customer d WHERE d.CustomerID = f.CustomerID)) AS CustOrphans,
  (SELECT COUNT(*) FROM fact_sales f WHERE NOT EXISTS
      (SELECT 1 FROM dim_product d WHERE d.ProductID = f.ProductID))    AS ProdOrphans,
  (SELECT COUNT(*) FROM fact_sales f WHERE NOT EXISTS
      (SELECT 1 FROM dim_region d WHERE d.RegionID = f.RegionID))       AS RegOrphans;
GO
/*  EXPECT: 0 | 0 | 0    — because orphans were mapped, not dropped.     */

-- How much revenue sits on the Unknown members? Always quantify.
SELECT SUM(SalesAmount) AS RevenueOnUnknownKeys
FROM   fact_sales
WHERE  CustomerID='UNKNOWN' OR ProductID='UNKNOWN' OR RegionID='UNKNOWN';
GO


/* =====================================================================
   STEP 7 GATE:
     - exactly 3 OrderStatus values
     - 0 unparsed dates
     - 0 orphans
     - decision register written into the README
   Then go to sql/04_analysis.sql.
   ===================================================================== */
