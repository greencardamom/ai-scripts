mkdir optimized_gs
for file in *.pdf; do
  output_file="optimized_gs/${file%.pdf}_optimized.pdf"
  echo "Processing '$file' with Ghostscript (/ebook setting)..."
  gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/screen \
     -dNOPAUSE -dQUIET -dBATCH -sOutputFile="$output_file" "$file"
done
echo "Ghostscript processing complete."
