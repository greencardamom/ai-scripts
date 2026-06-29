#!/usr/bin/bash

# --- Configuration ---
input_pdf="${1}.pdf"  # Replace with your input PDF filename
output_prefix="${1}"            # Replace with your desired output prefix
pages_per_file="${2}"               # Number of pages per output file
# ---------------------

# Check if input file exists
if [ ! -f "$input_pdf" ]; then
    echo "Error: Input file '$input_pdf' not found."
    exit 1
fi

# Get total number of pages
total_pages=$(qpdf --show-npages "$input_pdf")
if [ $? -ne 0 ] || ! [[ "$total_pages" =~ ^[0-9]+$ ]] || [ "$total_pages" -eq 0 ]; then
    echo "Error: Could not get a valid page count from '$input_pdf'."
    exit 1
fi
echo "Total pages in '$input_pdf': $total_pages"

# Calculate number of output files needed
num_files=$(( (total_pages + pages_per_file - 1) / pages_per_file ))
echo "Will create $num_files output files."

# --- Calculate padding widths ---
# Padding for the sequential file number (based on total number of files)
# Example: If num_files is 9, width is 1. If 15, width is 2. If 120, width is 3.
pad_num_files=${#num_files}

# Padding for the page numbers (based on total number of pages)
# Example: If total_pages is 80, width is 2. If 350, width is 3. If 12000, width is 5.
pad_pages=${#total_pages}
# --- End padding calculation ---


# Loop and split
start_page=1
for (( i=1; i<=num_files; i++ )); do
    # Calculate end page for the current chunk
    end_page=$(( start_page + pages_per_file - 1 ))

    # Adjust end page if it exceeds total pages
    if [ "$end_page" -gt "$total_pages" ]; then
        end_page=$total_pages
    fi

    # Format the parts using printf and calculated padding widths
    formatted_i=$(printf "%0${pad_num_files}d" "$i")
    formatted_start_page=$(printf "%0${pad_pages}d" "$start_page")
    formatted_end_page=$(printf "%0${pad_pages}d" "$end_page")

    # Construct the final output filename
    output_pdf="${output_prefix}_${formatted_i}_${formatted_start_page}-${formatted_end_page}.pdf"

    echo "Creating '$output_pdf' pages $start_page-$end_page ..."

    # Use qpdf to extract the page range
    qpdf "$input_pdf" --pages . $start_page-$end_page -- "$output_pdf"

    if [ $? -ne 0 ]; then
        echo "Error creating '$output_pdf'. Aborting."
        exit 1
    fi

    # Update start page for the next iteration
    start_page=$(( end_page + 1 ))
done

echo "Splitting complete."
exit 0

