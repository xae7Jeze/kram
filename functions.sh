# create random password
npw (){
  pwgen -s $((RANDOM % 10 + ${1:-10})) 1
}

# remove comments from xml files
remove_xml_comments(){
  perl -e '$_=join "",<>;s/<!--.*?-->//gs;s/\n\s*\n/\n/g;print' "$@"
}
