from pyspark.sql import SparkSession
import random

# Initialize SparkSession
spark = SparkSession.builder \
    .appName("Generate10GBCSV") \
    .config("spark.sql.shuffle.partitions", "400") \
    .config("spark.executor.instances", "1") \
    .config("spark.executor.cores", "4") \
    .config("spark.executor.memory", "2g") \
    .config("spark.driver.memory", "12") \
    .getOrCreate()

# Function to generate random rows
def generate_row():
    return {
        "id": random.randint(1, 1_000_000),
        "name": f"name_{random.randint(1, 1_000)}",
        "value": random.uniform(1.0, 100.0),
        "category": random.choice(["A", "B", "C", "D"])
    }

# Approximate size of each row in bytes (~100 bytes)
row_size = 100

# Number of rows to generate for ~10GB
num_rows = (10 * 1024**3) // row_size  # 10GB / size per row

# Create RDD and generate DataFrame
data_rdd = spark.sparkContext.parallelize(range(int(num_rows))).map(lambda _: generate_row())
data_df = spark.createDataFrame(data_rdd)

# Output path
output_path = "/opt/data/10gb_data.csv"  # Replace with your desired output path

# Write data to CSV
data_df.write.mode("overwrite").option("header", "true").csv(output_path)

print(f"10GB CSV data written to {output_path}")

# Stop the SparkSession
spark.stop()
