import os
import re
import time
import numpy as np
from google.cloud import storage
from concurrent.futures import ThreadPoolExecutor, as_completed

def test_pagerank():
    """
    Test PageRank implementation with a small graph.
    
    Graph structure:
      0 -> 1, 2
      1 -> 2
      2 -> 0
      3 -> 0, 1, 2
    
    - Node 0 has incoming links from 2 and 3
    - Node 1 has incoming links from 0 and 3
    - Node 2 has incoming links from 0, 1, and 3
    - Node 3 has no incoming links
    """

    test_adj_list = {
        0: [1, 2],
        1: [2],
        2: [0],
        3: [0, 1, 2]
    }
    
    num_nodes = 4
    pr = run_pagerank(test_adj_list, num_nodes, verbose=False)
    
    # Verify properties:
    # 1. Sum of all PageRanks should be close to 1.0
    pr_sum = sum(pr.values())
    print(f"Sum of PageRanks: {pr_sum:.6f} (should be about 1.0)")
    assert abs(pr_sum - 1.0) < 0.01, f"PageRank sum should be about 1.0, got {pr_sum}"
    
    # 2. Node 3 (no incoming links) should have the minimum PageRank
    print(f"Node 3 PageRank: {pr[3]:.6f} (should be lowest)")
    assert pr[3] == min(pr.values()), "Node 3 should have minimum PageRank"

    
    # 3. Node 2 (most incoming links) should have high PageRank
    print(f"Node 2 PageRank: {pr[2]:.6f} (should be highest)")
    assert pr[2] == max(pr.values()), "Node 2 should have highest PageRank"
    
    # Display all PageRanks
    print("\nPageRank results:")
    for node in sorted(pr.keys()):
        print(f"Node {node}: {pr[node]:.6f}")
    
    print("All tests passed!\n")
    return True

def download_and_parse_blob(blob):
    """
    Download and parse a single blob to extract links.
    Returns (file_id, links) or None if not valid.
    """
    try:
        if not blob.name.endswith('.html'):
            return None
        
        # Extract file ID from name (e.g., 'pages/1.html' -> 1)
        match = re.search(r'(\d+)\.html$', blob.name)
        if not match:
            return None
        
        file_id = int(match.group(1))
        content = blob.download_as_text()
        
        # Extract links using regex
        links = [int(m) for m in re.findall(r'HREF="(\d+)\.html"', content)]
        
        return (file_id, links)
    except Exception as e:
        print(f"Error processing {blob.name}: {e}")
        return None

def calculate_stats(data, label):
    arr = np.array(data)
    print(f"\n--- {label} Stats ---")
    print(f"Average: {np.mean(arr):.2f}")
    print(f"Median:  {np.median(arr)}")
    print(f"Max:     {np.max(arr)}")
    print(f"Min:     {np.min(arr)}")
    print(f"Quintiles (20, 40, 60, 80): {np.percentile(arr, [20, 40, 60, 80])}")

def run_pagerank(adj_list, num_files, verbose=True):
    # Initial PR: 1/n
    pr = {node: 1.0 / num_files for node in range(num_files)}
    
    # Pre-calculate counts and incoming links
    out_counts = {node: len(adj_list[node]) if node in adj_list else 0 for node in range(num_files)}
    incoming = {node: [] for node in range(num_files)}

    for source, targets in adj_list.items():
        for t in targets:
            if t < num_files: 
                incoming[t].append(source)

    iteration = 0
    while True:
        new_pr = {}
        total_diff = 0
        
        # Formula: PR(A) = 0.15/n + 0.85 * Sum(PR(T)/C(T))
        for i in range(num_files):
            # Sum contributions from all pages pointing to i
            rank_sum = sum(pr[t_in] / out_counts[t_in] for t_in in incoming[i] if out_counts[t_in] > 0)
            
            # PR(A) = 0.15/n + 0.85(Sum)
            new_pr[i] = (0.15 / num_files) + (0.85 * rank_sum)
            
            # Calculate the difference for this specific node
            total_diff += abs(new_pr[i] - pr[i])
        
        iteration += 1
        
        # Convergence: Sum of absolute changes < 0.5% (0.005)
        if total_diff < 0.005:
            if verbose:
                print(f"Converged in {iteration} iterations")
            break
            
        pr = new_pr
    return pr

def main():
    import argparse
    
    parser = argparse.ArgumentParser(description='Compute PageRank')
    parser.add_argument('--bucket', type=str, default='alan-assign2', 
                        help='GCS bucket name (default: alan-assign2)')
    parser.add_argument('--prefix', type=str, default='pages/', 
                        help='Prefix/folder in bucket (default: pages/)')
    parser.add_argument('--workers', type=int, default=100, 
                        help='Number of parallel workers for downloading (default: 100)')
    parser.add_argument('--test', action='store_true', 
                        help='Run test only, skip bucket processing')
    args = parser.parse_args()
    
    # Run test
    if args.test:
        test_pagerank()
        return
    
    # --- Main Execution ---
    print(f"\n=== ANALYZING BUCKET: {args.bucket} ===")
    start_time = time.time()
    
    try:
        client = storage.Client()
        bucket = client.get_bucket(args.bucket)
        
        print(f"Listing files in gs://{args.bucket}/{args.prefix}...")
        blobs = list(bucket.list_blobs(prefix=args.prefix))
        print(f"Found {len(blobs)} blobs, starting parallel download...")
        
        adj_list = {}
        file_count = 0
        
        # Use ThreadPoolExecutor for parallel downloads
        print(f"Using {args.workers} parallel workers...")
        with ThreadPoolExecutor(max_workers=args.workers) as executor:
            # Submit all tasks
            future_to_blob = {executor.submit(download_and_parse_blob, blob): blob for blob in blobs}
            
            # Process completed tasks
            for future in as_completed(future_to_blob):
                result = future.result()
                if result is not None:
                    file_id, links = result
                    adj_list[file_id] = links
                    file_count += 1
                    
                    if file_count % 1000 == 0:
                        print(f"  Processed {file_count} files...")
        
        print(f"Total files processed: {file_count}")    

        # Calculate Degrees for Stats
        print("\nCalculating link statistics...")
        in_degrees = [0] * file_count
        out_degrees = [len(adj_list.get(i, [])) for i in range(file_count)]
        for links in adj_list.values():
            for l in links:
                if l < file_count:
                    in_degrees[l] += 1
        
        calculate_stats(in_degrees, "Incoming Links")
        calculate_stats(out_degrees, "Outgoing Links")
        
        # Run PageRank
        print("\nRunning PageRank algorithm...")
        pr_results = run_pagerank(adj_list, file_count)
        
        # Output Top 5
        top_5 = sorted(pr_results.items(), key=lambda x: x[1], reverse=True)[:5]
        print("\n=== Top 5 Pages by PageRank ===")
        for i, (idx, score) in enumerate(top_5, 1):
            print(f"{i}. Page {idx}.html: {score:.6f}")
        
        elapsed = time.time() - start_time
        print(f"\n=== Total Runtime: {elapsed:.2f} seconds ===")
        
    except Exception as e:
        print(f"ERROR: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()