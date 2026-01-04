public class CaseEmailFileGeneratorBatch implements Database.Batchable<Integer>, Database.Stateful {
    
    private Integer totalRecordsToCreate;
    private Integer uniqueFilesCreated = 0;       // Track how many files we've made in this job
    private Integer MAX_UNIQUE_FILES;             // The safety limit (default 2400)
    private Id fallbackContentDocumentId;         // The backup file ID for when we hit the limit
    
    // Constructor
    // count: Total records to create (e.g., 10,000)
    // safetyLimit: How many unique files to allow before switching to backup (Max 2500 allowed by SF)
    public CaseEmailFileGeneratorBatch(Integer count, Integer safetyLimit) {
        this.totalRecordsToCreate = count;
        // Default to 2400 if user passes null, to leave a buffer of 100 for other users/processes
        this.MAX_UNIQUE_FILES = (safetyLimit == null) ? 2400 : safetyLimit;
    }
    public Iterable<Integer> start(Database.BatchableContext bc) {
        // 1. Create the "Fallback" file to use when we run out of limits
        ContentVersion fallback = new ContentVersion(
            Title = 'Limit_Reached_Fallback_File',
            PathOnClient = 'Fallback.txt',
            VersionData = Blob.valueOf('Daily ContentPublication Limit reached. This file is shared for the remainder.'),
            IsMajorVersion = true
        );
        insert fallback;
        
        // Store the ID for later use
        this.fallbackContentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :fallback.Id].ContentDocumentId;
        // 2. Setup Scope
        List<Integer> scope = new List<Integer>();
        for (Integer i = 1; i <= totalRecordsToCreate; i++) {
            scope.add(i);
        }
        return scope;
    }
    public void execute(Database.BatchableContext bc, List<Integer> scope) {
        // --- Step 1: Create Cases ---
        List<Case> casesToInsert = new List<Case>();
        for (Integer i : scope) {
            casesToInsert.add(new Case(
                Subject = 'Case ' + i + ' ' + System.currentTimeMillis(),
                Status = 'New',
                Origin = 'Email'
            ));
        }
        insert casesToInsert;
        
        // --- Step 2: Create EmailMessages (1 per Case for simplicity in this logic) ---
        List<EmailMessage> emailsToInsert = new List<EmailMessage>();
        for (Case c : casesToInsert) {
            emailsToInsert.add(new EmailMessage(
                ParentId = c.Id,
                Subject = 'Ref: ' + c.Subject,
                FromAddress = 'customer@example.com',
                ToAddress = 'support@company.com',
                TextBody = 'Please see attached.',
                Incoming = true
            ));
        }
        insert emailsToInsert;
        
        // --- Step 3: Handle Files (The Hybrid Logic) ---
        List<ContentVersion> uniqueVersionsToInsert = new List<ContentVersion>();
        List<EmailMessage> emailsGettingUniqueFiles = new List<EmailMessage>();
        List<EmailMessage> emailsGettingFallbackFile = new List<EmailMessage>();
        
        for (EmailMessage em : emailsToInsert) {
            // Check if we have room in the limit to make a unique file
            if (uniqueFilesCreated < MAX_UNIQUE_FILES) {
                // PLAN: Create Unique File
                ContentVersion cv = new ContentVersion(
                    Title = 'Unique_File_For_' + em.Id,
                    PathOnClient = 'Evidence_' + em.Id + '.txt',
                    VersionData = Blob.valueOf('Unique content for email ' + em.Id),
                    IsMajorVersion = true
                );
                uniqueVersionsToInsert.add(cv);
                emailsGettingUniqueFiles.add(em); // Keep track to link later
                uniqueFilesCreated++;
            } else {
                // PLAN: Use Fallback File
                emailsGettingFallbackFile.add(em);
            }
        }
        
        // --- Step 4: Insert Unique Files and Link Them ---
        List<ContentDocumentLink> linksToInsert = new List<ContentDocumentLink>();
        
        if (!uniqueVersionsToInsert.isEmpty()) {
            insert uniqueVersionsToInsert;
            
            // Re-query to get ContentDocumentIds
            List<ContentVersion> insertedVersions = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :uniqueVersionsToInsert];
            
            // Map them back to the emails (Orders correspond because lists were built synchronously)
            for (Integer i = 0; i < insertedVersions.size(); i++) {
                linksToInsert.add(new ContentDocumentLink(
                    LinkedEntityId = emailsGettingUniqueFiles[i].Id,
                    ContentDocumentId = insertedVersions[i].ContentDocumentId,
                    ShareType = 'V',
                    Visibility = 'AllUsers'
                ));
            }
        }
        
        // --- Step 5: Link Fallback Files (For the overflow) ---
        if (!emailsGettingFallbackFile.isEmpty()) {
            for (EmailMessage em : emailsGettingFallbackFile) {
                linksToInsert.add(new ContentDocumentLink(
                    LinkedEntityId = em.Id,
                    ContentDocumentId = this.fallbackContentDocumentId, // REUSE ID
                    ShareType = 'V',
                    Visibility = 'AllUsers'
                ));
            }
        }
        
        insert linksToInsert;
    }
    public void finish(Database.BatchableContext bc) {
        System.debug('Batch Complete.');
        System.debug('Unique Files Created: ' + uniqueFilesCreated);
        System.debug('Shared Files Used: ' + (totalRecordsToCreate - uniqueFilesCreated));
    }
}
 