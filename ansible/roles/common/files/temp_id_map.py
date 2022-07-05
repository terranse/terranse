# For some reason Ansible could not accept the file name extension ('.py'), so file is intentionally stored w/o ext.
with open('./temp_id_map', 'w') as f:
    for uid in range(1000, 65536):
        f.write("%d:%d:65536\n" %(uid,uid*65536))