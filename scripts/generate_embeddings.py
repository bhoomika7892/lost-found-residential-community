from sentence_transformers import SentenceTransformer
import psycopg
from pgvector.psycopg import register_vector

# Load the sentence embedding model
model = SentenceTransformer("all-MiniLM-L6-v2")

# Connect to the project's PostgreSQL database
DATABASE_URL = "postgresql://lostfound_user:dbms2026@localhost:55433/lost_found_db"


def build_item_text(row):
    item_name, color, brand, description = row

    parts = [
        f"Item: {item_name}",
        f"Color: {color}" if color else None,
        f"Brand: {brand}" if brand else None,
        f"Description: {description}" if description else None,
    ]

    return ". ".join(part for part in parts if part)


def main():
    with psycopg.connect(DATABASE_URL) as conn:
        register_vector(conn)

        with conn.cursor() as cur:
            cur.execute("""
                SELECT item_id, item_name, color, brand, description
                FROM item
                ORDER BY item_id;
            """)
            rows = cur.fetchall()

            if not rows:
                print("No items found.")
                return

            texts = [build_item_text(row[1:]) for row in rows]
            embeddings = model.encode(
                texts,
                normalize_embeddings=True
            )

            for row, embedding in zip(rows, embeddings):
                cur.execute(
                    """
                    UPDATE item
                    SET embedding = %s
                    WHERE item_id = %s;
                    """,
                    (embedding.tolist(), row[0])
                )

            conn.commit()
            print(f"Generated and saved embeddings for {len(rows)} items.")


if __name__ == "__main__":
    main()